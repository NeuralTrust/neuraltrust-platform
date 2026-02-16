-- Create the database
CREATE DATABASE IF NOT EXISTS neuraltrust;

-- Switch to the database
USE neuraltrust;

-- Migration tracking table
CREATE TABLE IF NOT EXISTS schema_migrations
(
    migrationHash String,
    appliedAt DateTime64(6, 'UTC') DEFAULT now64(6),
    PRIMARY KEY (migrationHash)
) ENGINE = ReplacingMergeTree(appliedAt)
ORDER BY (migrationHash);

-- Teams table
CREATE TABLE IF NOT EXISTS teams
(
    id String,
    name String,
    type String,
    modelProvider String,
    modelBaseUrl String,
    modelApiKey String,
    modelName String,
    modelApiVersion String,
    modelDeploymentName String,
    modelExtraHeaders String,
    dataPlaneEndpoint String,
    siemConfig String,
    createdAt DateTime64(6, 'UTC'),
    updatedAt DateTime64(6, 'UTC'),
    PRIMARY KEY (id)
) ENGINE = MergeTree()
ORDER BY (id);

-- Apps table
CREATE TABLE IF NOT EXISTS apps
(
    id String,
    name String,
    teamId String,
    createdAt DateTime64(6, 'UTC'),
    updatedAt DateTime64(6, 'UTC'),
    PRIMARY KEY (id)
) ENGINE = MergeTree()
ORDER BY (id);

CREATE TABLE IF NOT EXISTS audit_logs_ingest
(
    id String,
    version String DEFAULT '1.0',
    team_id String,
    timestamp DateTime64(6, 'UTC'),
    event_type String,
    event_category String,
    event_description String DEFAULT '',
    event_status String DEFAULT '',
    event_error_message String DEFAULT '',
    actor_id String DEFAULT '',
    actor_email String DEFAULT '',
    actor_type String DEFAULT '',
    target_type String DEFAULT '',
    target_id String DEFAULT '',
    target_name String DEFAULT '',
    context_ip_address String DEFAULT '',
    context_user_agent String DEFAULT '',
    context_session_id String DEFAULT '',
    context_request_id String DEFAULT '',
    changes_previous String DEFAULT '{}',
    changes_current String DEFAULT '{}',
    metadata String DEFAULT '{}',
    event_date Date MATERIALIZED toDate(timestamp),

    INDEX idx_team_id (team_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_event_type (event_type) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_event_category (event_category) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_event_status (event_status) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_actor_id (actor_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_target_id (target_id) TYPE bloom_filter(0.01) GRANULARITY 1
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (team_id, timestamp, id)
TTL event_date + INTERVAL 12 MONTH;

-- Classifiers table
CREATE TABLE IF NOT EXISTS classifiers
(
    id UInt32,
    name String,
    scope String,
    enabled UInt8,
    teamId String,
    description String,
    instructions String,
    type String,
    createdAt DateTime64(6, 'UTC'),
    updatedAt DateTime64(6, 'UTC'),
    PRIMARY KEY (id)
) ENGINE = MergeTree()
ORDER BY (id);

-- Classes table
CREATE TABLE IF NOT EXISTS classes
(
    id UInt32,
    name String,
    classifierId UInt32,
    description String,
    createdAt DateTime64(6, 'UTC'),
    updatedAt DateTime64(6, 'UTC'),
    PRIMARY KEY (id)
) ENGINE = MergeTree()
ORDER BY (id);

-- Tests table
CREATE TABLE IF NOT EXISTS tests (
    id String,
    scenarioId String,
    targetId String,
    testCase String, -- JSON in ClickHouse is stored as String
    context String,  -- JSON in ClickHouse is stored as String
    type String,
    contextKeys Array(String),
    createdAt DateTime DEFAULT now(),
    updatedAt DateTime DEFAULT now(),
    sign Int8
) ENGINE = CollapsingMergeTree(sign)
ORDER BY (id, scenarioId, targetId);

-- Tests Runs table
CREATE TABLE IF NOT EXISTS test_runs (
    id String,
    scenarioId String,
    targetId String,
    testId String,
    runId String,
    executionId String,
    type String,
    contextKeys Array(String),
    failure UInt8, -- Boolean in ClickHouse is represented as UInt8 (0 or 1)
    failCriteria String,
    testCase String, -- JSON stored as String
    score String,    -- JSON stored as String
    executionTimeSeconds Int32 NULL,
    runAt DateTime DEFAULT now(),
    sign Int8,
    PRIMARY KEY (id)
) ENGINE = CollapsingMergeTree(sign)
ORDER BY (id);

-- GPT Usage table
CREATE TABLE IF NOT EXISTS gpt_usage
(
    team_id String,
    gizmo_id String,
    name String,
    description String,
    author_user_id String,
    author_display_name String,
    author_is_verified UInt8,
    categories Array(String),
    created_at String,
    updated_at String,
    num_interactions Int64,
    model String,
    tools Array(String),
    kind String,
    tags Array(String),
    share_recipient String,
    workspace_id String,
    organization_id String,
    sharing_targets String,
    current_sharing String,
    workspace_approved UInt8,
    workspace_approval_date String,
    detected_at Int64,
    detected_time DateTime MATERIALIZED fromUnixTimestamp64Milli(detected_at),
    timestamp String,
    extensionVersion String,
    event_date Date MATERIALIZED parseDateTime64BestEffort(timestamp),
    event_hour DateTime MATERIALIZED toStartOfHour(parseDateTime64BestEffort(timestamp)),
    PRIMARY KEY (team_id, gizmo_id, author_user_id)
) ENGINE = ReplacingMergeTree(detected_at)
PARTITION BY toYYYYMM(event_date)
ORDER BY (team_id, gizmo_id, author_user_id)
TTL event_date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;


-- ============================================================================
-- METRICS TABLE: Main data source for all dashboard metrics
-- ============================================================================
CREATE TABLE IF NOT EXISTS metrics
(
    -- Identity fields
    trace_id String,
    team_id String,
    gateway_id String,
    engine_id String,
    rule_id String,
    policy_id String,
    interaction_id String,
    conversation_id String,
    session_id String,
    user_id String DEFAULT '',
    
    -- Request/Response
    path String,
    input String,
    output String,
    task String,
    type String,
    method String,
    params String,
    upstream String,
    plugin String,
    request_headers String,
    response_headers String,
    status_code Int32,
    
    -- Timing
    start_timestamp Int64,
    end_timestamp Int64,
    latency Int32,
    
    -- User info
    user_ip String,
    browser String DEFAULT '',
    device String DEFAULT '',
    os String DEFAULT '',
    locale String DEFAULT '',
    location String DEFAULT '',
    
    -- Materialized fields
    start_time DateTime MATERIALIZED fromUnixTimestamp64Milli(start_timestamp),
    end_time DateTime MATERIALIZED fromUnixTimestamp64Milli(end_timestamp),
    event_date Date MATERIALIZED toDate(start_time),
    event_hour DateTime MATERIALIZED toStartOfHour(start_time),
    
    -- Indexes
    INDEX idx_team_id (team_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_gateway_id (gateway_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_engine_id (engine_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_rule_id (rule_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_user_id (user_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_conversation_id (conversation_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_session_id (session_id) TYPE bloom_filter(0.01) GRANULARITY 1
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_hour, team_id, gateway_id, engine_id, trace_id)
TTL event_date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;


-- ============================================================================
-- TOPICS_CLASSIFIED TABLE: Topics/Classifications linked to traces
-- One row per trace + classifier + label combination
-- Receives topic classification data directly from ingestion
-- ============================================================================
CREATE TABLE IF NOT EXISTS topics_classified
(
    -- Link to trace (from interaction)
    trace_id String,
    team_id String,
    
    -- Classification data
    classifier_id UInt32,
    category String DEFAULT '',
    label Array(String),             -- Array of labels from classification
    score Nullable(Float64),         -- For single-score classifiers
    
    -- Timestamp (milliseconds)
    timestamp Int64,
    
    -- Materialized fields
    event_time DateTime MATERIALIZED fromUnixTimestamp64Milli(timestamp),
    event_date Date MATERIALIZED toDate(event_time),
    day Date MATERIALIZED toDate(event_time),
    
    -- Indexes
    INDEX idx_team_id (team_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_classifier_id (classifier_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_label (label) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_category (category) TYPE bloom_filter(0.01) GRANULARITY 1
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, team_id, classifier_id, trace_id)
TTL event_date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS discover_events (
    timestamp UInt64,
    submission_timestamp UInt64,
    event_type String,
    user_id String,
    user_email String,
    action String,
    application_id String,
    application_name String,
    url String,
    session_id String,
    team_id String,
    tab_id Nullable(UInt32),
    extension_version Nullable(String),
    user_agent Nullable(String),
    prompt_text Nullable(String),
    content_length Nullable(UInt32),
    sensitive_data_types Array(String) DEFAULT [],
    sensitive_data_categories Array(String) DEFAULT [],
    sensitive_data_level Nullable(String),
    sensitive_data_count UInt32 DEFAULT 0,
    detection_method Nullable(String),
    category Nullable(String),
    frame_type Nullable(String),
    date Date DEFAULT toDate(timestamp / 1000),
    hour DateTime DEFAULT toDateTime(timestamp / 1000),
    has_sensitive_data UInt8 DEFAULT if(sensitive_data_count > 0, 1, 0),
    is_blocked UInt8 DEFAULT if(action = 'block', 1, 0),
    is_warned UInt8 DEFAULT if(action = 'warn', 1, 0),
    event_format String DEFAULT if(event_type IN ('navigation', 'widget_detected'), 'old', 'new'),
    INDEX idx_team_id (team_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_application_id (application_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_event_type (event_type) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_action (action) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_session_id (session_id) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_sensitive_level (sensitive_data_level) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_category (category) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_has_sensitive (has_sensitive_data) TYPE minmax GRANULARITY 1,
    INDEX idx_date (date) TYPE minmax GRANULARITY 1,
    INDEX idx_hour (hour) TYPE minmax GRANULARITY 1
    
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (team_id, timestamp, session_id)
TTL date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;


-- ============================================================================
-- MATERIALIZED VIEWS FOR DASHBOARD CHARTS
-- All views read from the metrics table directly
-- ============================================================================

-- ============================================================================
-- 1. DAILY METRICS: Messages & Conversations per day
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS daily_metrics
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, team_id, gateway_id, engine_id, day)
AS SELECT
    team_id,
    gateway_id,
    engine_id,
    event_date,
    toStartOfDay(start_time) as day,
    uniqState(interaction_id) as messages_count_state,
    uniqStateIf(conversation_id, conversation_id != '') as conversations_count_state
FROM metrics
WHERE task = 'message' AND type = 'trace'
GROUP BY team_id, gateway_id, engine_id, event_date, toStartOfDay(start_time);

-- ============================================================================
-- 2. USER METRICS: Users, Sessions, New Users
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS user_metrics
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, team_id, gateway_id, engine_id, day)
AS SELECT
    team_id,
    gateway_id,
    engine_id,
    event_date,
    toStartOfDay(start_time) as day,
    uniqState(user_id) as users_count_state,
    uniqState(session_id) as sessions_count_state,
    uniqStateIf(user_id, is_first_time) as new_users_count_state
FROM (
    SELECT 
        team_id,
        gateway_id,
        engine_id,
        start_time,
        event_date,
        user_id,
        session_id,
        min(start_timestamp) OVER (PARTITION BY team_id, gateway_id, engine_id, user_id) = start_timestamp as is_first_time
    FROM metrics
    WHERE task = 'message' AND type = 'trace' AND user_id != ''
)
GROUP BY team_id, gateway_id, engine_id, event_date, toStartOfDay(start_time);

-- ============================================================================
-- 3. COUNTRY METRICS: Sessions by country
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS country_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, team_id, gateway_id, engine_id, day, country)
AS SELECT
    team_id,
    gateway_id,
    engine_id,
    event_date,
    toStartOfDay(start_time) as day,
    location as country,
    uniq(session_id) as sessions_count
FROM metrics
WHERE task = 'message' AND type = 'trace' AND location != ''
GROUP BY team_id, gateway_id, engine_id, event_date, toStartOfDay(start_time), location;

-- ============================================================================
-- 4. SINGLE MESSAGE RATE: View for conversations with 1 message (Protect)
-- Note: Named differently to not conflict with Observe's single_message_rate_view
-- ============================================================================
CREATE OR REPLACE VIEW single_message_rate_protect_view AS
SELECT
    team_id,
    gateway_id,
    engine_id,
    event_date,
    day,
    countIf(message_count = 1) as single_message_conversations,
    count() as total_conversations,
    if(count() > 0, 100.0 * countIf(message_count = 1) / count(), 0) as single_message_rate
FROM (
    SELECT
        team_id,
        gateway_id,
        engine_id,
        event_date,
        toStartOfDay(start_time) as day,
        conversation_id,
        count() as message_count
    FROM metrics
    WHERE task = 'message' AND type = 'trace'
    GROUP BY team_id, gateway_id, engine_id, event_date, toStartOfDay(start_time), conversation_id
)
GROUP BY team_id, gateway_id, engine_id, event_date, day;

-- ============================================================================
-- 5. TOPIC KPIs MATERIALIZED VIEW: Aggregated daily topics
-- Joins topics_classified with metrics to get gateway_id, conversation_id, etc.
-- Uses arrayJoin to explode label array into individual rows
-- ============================================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS protect_topics_1d
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (day, team_id, gateway_id, engine_id, classifier_id, label)
AS SELECT
    t.day as day,
    t.team_id as team_id,
    m.gateway_id as gateway_id,
    m.engine_id as engine_id,
    t.classifier_id as classifier_id,
    arrayJoin(t.label) as label,
    uniqState(m.conversation_id) AS conversations_count_state,
    uniqState(m.interaction_id) AS messages_count_state
FROM topics_classified t
INNER JOIN metrics m ON t.trace_id = m.trace_id AND t.team_id = m.team_id
WHERE length(t.label) > 0 AND m.type = 'trace'
GROUP BY t.day, t.team_id, m.gateway_id, m.engine_id, t.classifier_id, label;

-- ============================================================================
-- 6. UNIFIED METRICS VIEW: Single query for all dashboard metrics
-- ============================================================================
CREATE OR REPLACE VIEW dashboard_metrics AS
SELECT
    d.team_id,
    d.gateway_id,
    d.engine_id,
    d.event_date,
    d.day,
    -- Messages & Conversations
    uniqMerge(d.messages_count_state) AS messages_count,
    uniqMerge(d.conversations_count_state) AS conversations_count,
    -- Dialogue volume (messages per conversation)
    if(uniqMerge(d.conversations_count_state) > 0,
       uniqMerge(d.messages_count_state) / uniqMerge(d.conversations_count_state),
       0) AS dialogue_volume,
    -- User metrics
    uniqMerge(u.users_count_state) AS users_count,
    uniqMerge(u.sessions_count_state) AS sessions_count,
    uniqMerge(u.new_users_count_state) AS new_users_count,
    -- Sessions per user
    if(uniqMerge(u.users_count_state) > 0, 
       uniqMerge(u.sessions_count_state) / uniqMerge(u.users_count_state), 
       0) AS sessions_per_user
FROM daily_metrics d
LEFT JOIN user_metrics u 
    ON d.team_id = u.team_id 
    AND d.gateway_id = u.gateway_id 
    AND d.engine_id = u.engine_id
    AND d.event_date = u.event_date 
    AND d.day = u.day
GROUP BY d.team_id, d.gateway_id, d.engine_id, d.event_date, d.day;

-- ============================================================================
-- 7. COUNTRY DISTRIBUTION VIEW
-- ============================================================================
CREATE OR REPLACE VIEW country_distribution AS
SELECT
    team_id,
    gateway_id,
    engine_id,
    event_date,
    day,
    country,
    sum(sessions_count) as sessions_count
FROM country_metrics
GROUP BY team_id, gateway_id, engine_id, event_date, day, country
ORDER BY team_id, gateway_id, engine_id, event_date, day, sessions_count DESC;

-- ============================================================================
-- 8. TOPIC KPIs VIEW for Protect (gateway/engine)
-- ============================================================================
CREATE OR REPLACE VIEW protect_topics_view AS
SELECT
    day,
    team_id,
    gateway_id,
    engine_id,
    classifier_id,
    label,
    uniqMerge(conversations_count_state) AS conversations,
    uniqMerge(messages_count_state) AS messages,
    if(uniqMerge(conversations_count_state) > 0,
       uniqMerge(messages_count_state) / uniqMerge(conversations_count_state),
       0) AS dialogue_volume
FROM protect_topics_1d
GROUP BY day, team_id, gateway_id, engine_id, classifier_id, label;


-- ============================================================================
-- NEURALTRUST AGENT TRACES SCHEMA - FULLY AUTOMATED
-- ============================================================================
-- All tables are auto-populated from traces/spans via materialized views
-- No external scripts needed!

-- ============================================================================
-- BASE TABLES (Written by Kafka Connect)
-- ============================================================================


-- GUARDIAN_INVOCATIONS - Security/policy checks
CREATE TABLE IF NOT EXISTS neuraltrust.guardian_invocations (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    invocation_id String,
    trace_id String,
    agent_id String,
    check_type String,  -- permission_check, rate_limit, content_filter, etc.
    result Enum8('allowed' = 1, 'blocked' = 2, 'flagged' = 3),
    risk_score Float32,
    reason String,
    metadata String,  -- JSON
    timestamp DateTime64(6, 'UTC'),
    date Date MATERIALIZED toDate(timestamp)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (team_id, agent_id, timestamp)
TTL date + INTERVAL 90 DAY;
