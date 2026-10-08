#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders the documented install shapes with the chart at BASE and with the
# working tree, and reports what an existing install would see change on upgrade.
#
#   scripts/render-diff.rb <base-ref> [--labels a,b] [--summary FILE]
#
# Both sides use BASE's copy of each values file: existing installs keep their
# values across an upgrade, so a head that needs new values is a regression.
#
# Exit 0 when nothing changed (image tags aside), or when every change is
# covered by a label:
#   render-diff-approved  any rendered change
#   breaking-change       a Secret, PVC or StatefulSet removed, a Secret key
#                         removed, an immutable field changed, or a shape that
#                         rendered now fails

require 'yaml'
require 'open3'
require 'tmpdir'
require 'set'

CHART_DIR = File.expand_path('..', __dir__)

SHAPES = {
  'hybrid'                   => %w[values-required.yaml],
  'hybrid-managed'           => %w[values-hybrid.yaml.example],
  'hybrid-trustgate'         => %w[values-trustgate.yaml.example],
  'hybrid-trustguard'        => %w[values-trustguard.yaml.example],
  'hybrid-red-teaming'       => %w[values-red-teaming.yaml.example],
  'hybrid-gpu'               => %w[values-required.yaml values-dataplane-gpu.yaml.example],
  'hybrid-openshift'         => %w[values-required.yaml values-openshift.yaml],
  'external'                 => %w[values-external.yaml.example],
  'external-managed'         => %w[values-managed-datastores.yaml.example],
  'external-trustguard-only' => %w[values-external.yaml.example values-external-trustguard-only.yaml.example],
  'external-observability'   => %w[values-external.yaml.example values-observability-self-hosted.yaml.example],
}.freeze
API_VERSIONS = %w[route.openshift.io/v1 monitoring.coreos.com/v1].freeze

# Removing these loses credentials or data on upgrade; other removals are diffs.
DATA_KINDS = %w[Secret PersistentVolumeClaim StatefulSet].freeze
IMMUTABLE = {
  'Deployment' => [%w[spec selector]],
  'DaemonSet' => [%w[spec selector]],
  'StatefulSet' => [%w[spec selector], %w[spec serviceName], %w[spec volumeClaimTemplates]],
  'PersistentVolumeClaim' => [%w[spec storageClassName], %w[spec accessModes]],
}.freeze
VOLATILE_LABELS = %w[helm.sh/chart app.kubernetes.io/version].freeze

def sh!(*cmd)
  out, err, status = Open3.capture3(*cmd)
  abort "#{cmd.join(' ')} failed:\n#{err}" unless status.success?
  out
end

def render(chart, values)
  args = ['helm', 'template', 'neuraltrust-platform', chart, '--namespace', 'neuraltrust', '--is-upgrade']
  values.each { |v| args += ['-f', v] }
  API_VERSIONS.each { |a| args += ['--api-versions', a] }
  out, err, status = Open3.capture3(*args)
  return [nil, err.lines.grep(/Error:/).last.to_s.strip] unless status.success?

  docs = YAML.load_stream(out).select { |d| d.is_a?(Hash) && d['kind'] }
  [docs.to_h { |d| ["#{d['kind']}/#{d.dig('metadata', 'name')}", d] }, nil]
end

def image_tags(node, acc = Set.new)
  case node
  when Hash
    node.each do |k, v|
      if k == 'image' && v.is_a?(String) && v.split('/').last.include?(':')
        acc << v.split(':').last
      else
        image_tags(v, acc)
      end
    end
  when Array then node.each { |v| image_tags(v, acc) }
  end
  acc
end

# Image tags and their echoes (APPLICATION_VERSION and the like) move on every
# release; tags present on one side only are masked wherever they appear.
def normalise(node, moved_tags)
  case node
  when Hash
    node.each_with_object({}) do |(k, v), h|
      h[k] = if VOLATILE_LABELS.include?(k) || k.to_s.start_with?('checksum/') then '<volatile>'
             elsif k == 'image' && v.is_a?(String) then v.sub(/:[^:\/]+\z/, ':<tag>')
             else normalise(v, moved_tags)
             end
    end
  when Array then node.map { |v| normalise(v, moved_tags) }
  when String then moved_tags.reduce(node) { |s, t| s.gsub(/(?<![\w.])#{Regexp.escape(t)}(?![\w.])/, '<tag>') }
  else node
  end
end

def mask_secret(doc)
  return doc unless doc['kind'] == 'Secret'

  %w[data stringData].each do |f|
    doc[f] = doc[f].transform_values { '<secret>' } if doc[f].is_a?(Hash)
  end
  doc
end

def secret_keys(doc)
  %w[data stringData].flat_map { |f| doc[f].is_a?(Hash) ? doc[f].keys : [] }
end

def compare(base, head)
  findings = []
  (base.keys - head.keys).each do |key|
    kind = key.split('/').first
    findings << [DATA_KINDS.include?(kind) ? :breaking : :diff, key, 'removed']
  end
  (head.keys - base.keys).each { |key| findings << [:diff, key, 'added'] }
  (base.keys & head.keys).each do |key|
    b = base[key]
    h = head[key]
    next if b == h

    kind = key.split('/').first
    lost = secret_keys(b) - secret_keys(h)
    findings << [:breaking, key, "Secret keys removed: #{lost.join(', ')}"] if kind == 'Secret' && lost.any?
    (IMMUTABLE[kind] || []).each do |path|
      findings << [:breaking, key, "#{path.join('.')} changed (immutable)"] if b.dig(*path) != h.dig(*path)
    end
    findings << [:diff, key, 'changed']
  end
  findings
end

def unified(key, b, h)
  Dir.mktmpdir do |d|
    File.write("#{d}/base", b ? YAML.dump(b) : '')
    File.write("#{d}/head", h ? YAML.dump(h) : '')
    out, = Open3.capture2('diff', '-u', '--label', "base/#{key}", '--label', "head/#{key}", "#{d}/base", "#{d}/head")
    out
  end
end

base_ref = ARGV.shift or abort 'usage: render-diff.rb <base-ref> [--labels a,b] [--summary FILE]'
opts = ARGV.each_slice(2).to_h
labels = opts.fetch('--labels', '').split(',').map(&:strip).to_set

breaking = 0
changed = 0
report = []
tag_moves = Set.new

Dir.mktmpdir do |tmp|
  base_chart = File.join(tmp, 'base')
  Dir.mkdir(base_chart)
  sh!('sh', '-c', "git -C '#{CHART_DIR}' archive '#{base_ref}' | tar -x -C '#{base_chart}'")
  # Head renders from a copy so dependency builds never touch the working tree.
  head_chart = File.join(tmp, 'head')
  Dir.mkdir(head_chart)
  sh!('sh', '-c', "tar -C '#{CHART_DIR}' --exclude=.git --exclude=accounts --exclude=regions --exclude=local -cf - . | tar -x -C '#{head_chart}'")
  [base_chart, head_chart].each do |c|
    _, _, ok = Open3.capture3('helm', 'dependency', 'build', c)
    sh!('helm', 'dependency', 'update', '--skip-refresh', c) unless ok.success?
  end

  # The chart version is echoed into config (nt.chart_version); mask it like a tag.
  versions = [base_chart, head_chart].map { |c| YAML.load_file(File.join(c, 'Chart.yaml'))['version'].to_s }

  SHAPES.each do |shape, files|
    values = files.map { |f| File.join(base_chart, f) }
    next report << "- `#{shape}`: new shape, nothing to compare" unless values.all? { |v| File.exist?(v) }

    b, berr = render(base_chart, values)
    h, herr = render(head_chart, values)
    if berr
      report << "- `#{shape}`: does not render on base (#{berr}); skipped"
      next
    end
    if herr
      breaking += 1
      report << "- **breaking** `#{shape}`: rendered on base, fails now: #{herr}"
      next
    end

    bt = image_tags(b.values) << versions[0]
    ht = image_tags(h.values) << versions[1]
    tag_moves.merge((ht - bt).to_a - [versions[1]])
    bn = b.transform_values { |d| mask_secret(normalise(d, (bt - ht).to_a)) }
    hn = h.transform_values { |d| mask_secret(normalise(d, (ht - bt).to_a)) }

    findings = compare(bn, hn)
    next if findings.empty?

    report << "\n### `#{shape}`\n"
    findings.each do |sev, key, msg|
      sev == :breaking ? breaking += 1 : changed += 1
      report << "- #{sev == :breaking ? '**breaking**' : 'diff'} `#{key}`: #{msg}"
    end
    diff = findings.map { |_, key, _| key }.uniq.map { |key| unified(key, bn[key], hn[key]) }.join
    report << "\n<details><summary>rendered diff</summary>\n\n```diff\n#{diff}```\n</details>"
  end
end

blocked = (breaking.positive? && !labels.include?('breaking-change')) ||
          (changed.positive? && !(labels & %w[render-diff-approved breaking-change]).any?)
verdict = if breaking.zero? && changed.zero? then 'no change for existing installs'
          elsif blocked then 'blocked: label the PR if this change is intended'
          else 'changes approved by label'
          end

summary = ["## Render diff vs `#{base_ref}`: #{verdict}", '',
           "#{SHAPES.size} install shapes, #{breaking} breaking, #{changed} other changes."]
summary << "New image tags (not counted as a change): #{tag_moves.to_a.sort.join(', ')}" if tag_moves.any?
summary += report
text = summary.join("\n") + "\n"
opts['--summary'] ? File.write(opts['--summary'], text) : puts(text)
exit(blocked ? 1 : 0)
