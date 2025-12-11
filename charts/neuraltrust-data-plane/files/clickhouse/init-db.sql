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
    inputCost Float64,
    outputCost Float64,
    convTracking UInt8,
    userTracking UInt8,
    createdAt DateTime64(6, 'UTC'),
    updatedAt DateTime64(6, 'UTC'),
    PRIMARY KEY (id)
) ENGINE = MergeTree()
ORDER BY (id);

-- Classifiers table
CREATE TABLE IF NOT EXISTS classifiers
(
    id UInt32,
    name String,
    scope String,
    enabled UInt8,
    appId String,
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

-- Raw traces table
CREATE TABLE IF NOT EXISTS traces
(
    app_id String,
    team_id String,
    trace_id String,
    parent_id String,
    interaction_id String,
    conversation_id String,
    start_timestamp Int64,
    end_timestamp Int64,
    start_time DateTime MATERIALIZED fromUnixTimestamp64Milli(start_timestamp),
    end_time DateTime MATERIALIZED fromUnixTimestamp64Milli(end_timestamp),
    latency Int32,
    input String,
    output String,
    feedback_tag String,
    feedback_text String,
    channel_id String,
    session_id String,
    user_id String,
    user_ip String,
    user_email String,
    user_phone String,
    location String,
    locale String,
    device String,
    os String,
    browser String,
    task String,
    custom String,
    event_date Date MATERIALIZED toDate(start_time),
    event_hour DateTime MATERIALIZED toStartOfHour(start_time)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_hour, app_id, conversation_id, interaction_id)
TTL event_date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;


CREATE TABLE IF NOT EXISTS metrics
(
    gateway_id String,
    engine_id String,
    trace_id String,
    interaction_id String,
    conversation_id String,
    path String,
    input String,
    output String,
    session_id String,
    task String,
    type String,
    start_timestamp Int64,
    end_timestamp Int64,
    latency Int32,
    user_ip String,
    params String,
    method String,
    upstream String,
    plugin String,
    request_headers String,
    response_headers String,
    status_code Int32,
    start_time DateTime MATERIALIZED fromUnixTimestamp64Milli(start_timestamp),
    end_time DateTime MATERIALIZED fromUnixTimestamp64Milli(end_timestamp),
    event_date Date MATERIALIZED toDate(start_time),
    event_hour DateTime MATERIALIZED toStartOfHour(start_time)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_hour, gateway_id, engine_id, trace_id)
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

-- Processed traces table with KPIs
CREATE TABLE IF NOT EXISTS traces_processed
(
    -- Base fields from traces
    APP_ID String,
    TEAM_ID String,
    TRACE_ID String,
    PARENT_ID String,
    INTERACTION_ID String,
    CONVERSATION_ID String,
    SESSION_ID String,
    START_TIMESTAMP Int64,
    END_TIMESTAMP Int64,
    START_TIME DateTime MATERIALIZED fromUnixTimestamp64Milli(START_TIMESTAMP),
    END_TIME DateTime MATERIALIZED fromUnixTimestamp64Milli(END_TIMESTAMP),
    LATENCY Int32,
    INPUT String,
    OUTPUT String,
    FEEDBACK_TAG String DEFAULT '',
    FEEDBACK_TEXT String DEFAULT '',
    CHANNEL_ID String,
    USER_ID String,
    USER_IP String,
    USER_EMAIL String,
    USER_PHONE String,
    LOCATION String,
    LOCALE String,
    DEVICE String,
    OS String,
    BROWSER String,
    TASK String,
    CUSTOM String,

    -- KPI fields
    OUTPUT_CLASSIFIERS String, -- Store as JSON string
    TOKENS_SPENT_PROMPT Int32,
    TOKENS_SPENT_RESPONSE Int32,
    READABILITY_RESPONSE Float64,
    NUM_WORDS_PROMPT Int32,
    NUM_WORDS_RESPONSE Int32,
    LANG_PROMPT String,
    LANG_RESPONSE String,
    SENTIMENT_PROMPT String,
    SENTIMENT_PROMPT_POSITIVE Float64,
    SENTIMENT_PROMPT_NEGATIVE Float64,
    SENTIMENT_PROMPT_NEUTRAL Float64,
    SENTIMENT_RESPONSE String,
    SENTIMENT_RESPONSE_POSITIVE Float64,
    SENTIMENT_RESPONSE_NEGATIVE Float64,
    SENTIMENT_RESPONSE_NEUTRAL Float64,
    
    -- Partitioning fields
    EVENT_DATE Date MATERIALIZED toDate(START_TIME),
    EVENT_HOUR DateTime MATERIALIZED toStartOfHour(START_TIME)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_HOUR, APP_ID, CONVERSATION_ID, INTERACTION_ID)
TTL EVENT_DATE + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;

-- Create a materialized view with its own storage engine for conversation aggregation
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_conversations
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (APP_ID, CONVERSATION_ID)
AS SELECT
    APP_ID,
    CONVERSATION_ID,
    toDate(START_TIMESTAMP / 1000) as EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    min(START_TIMESTAMP) as FIRST_MESSAGE_TIMESTAMP,
    max(END_TIMESTAMP) as LAST_MESSAGE_TIMESTAMP,
    argMaxState(USER_ID, START_TIMESTAMP) as USER_ID_STATE,
    argMaxState(SESSION_ID, START_TIMESTAMP) as SESSION_ID_STATE,
    argMaxState(DEVICE, START_TIMESTAMP) as DEVICE_STATE,
    argMaxState(OS, START_TIMESTAMP) as OS_STATE,
    argMaxState(BROWSER, START_TIMESTAMP) as BROWSER_STATE,
    argMaxState(LOCALE, START_TIMESTAMP) as LOCALE_STATE,
    argMaxState(LOCATION, START_TIMESTAMP) as LOCATION_STATE,
    argMaxState(CHANNEL_ID, START_TIMESTAMP) as CHANNEL_ID_STATE,
    
    -- Conversation metrics
    countState() as DIALOGUE_VOLUME_STATE,
    
    -- Time metrics
    minState(START_TIMESTAMP) as MIN_START_TIMESTAMP_STATE,
    maxState(END_TIMESTAMP) as MAX_END_TIMESTAMP_STATE,
    
    -- Content metrics
    sumState(NUM_WORDS_PROMPT) as NUM_WORDS_PROMPT_TOTAL_STATE,
    avgState(NUM_WORDS_PROMPT) as NUM_WORDS_PROMPT_AVG_STATE,
    minState(NUM_WORDS_PROMPT) as NUM_WORDS_PROMPT_MIN_STATE,
    maxState(NUM_WORDS_PROMPT) as NUM_WORDS_PROMPT_MAX_STATE,
    
    sumState(NUM_WORDS_RESPONSE) as NUM_WORDS_RESPONSE_TOTAL_STATE,
    avgState(NUM_WORDS_RESPONSE) as NUM_WORDS_RESPONSE_AVG_STATE,
    minState(NUM_WORDS_RESPONSE) as NUM_WORDS_RESPONSE_MIN_STATE,
    maxState(NUM_WORDS_RESPONSE) as NUM_WORDS_RESPONSE_MAX_STATE,
    
    -- Latency metrics
    sumState(LATENCY) as TIME_LATENCY_SUM_STATE,
    avgState(LATENCY) as TIME_LATENCY_AVG_STATE,
    minState(LATENCY) as TIME_LATENCY_MIN_STATE,
    maxState(LATENCY) as TIME_LATENCY_MAX_STATE,
    
    -- Token metrics
    sumState(TOKENS_SPENT_PROMPT) as TOKENS_SPENT_PROMPT_TOTAL_STATE,
    avgState(TOKENS_SPENT_PROMPT) as TOKENS_SPENT_PROMPT_AVG_STATE,
    minState(TOKENS_SPENT_PROMPT) as TOKENS_SPENT_PROMPT_MIN_STATE,
    maxState(TOKENS_SPENT_PROMPT) as TOKENS_SPENT_PROMPT_MAX_STATE,
    
    sumState(TOKENS_SPENT_RESPONSE) as TOKENS_SPENT_RESPONSE_TOTAL_STATE,
    avgState(TOKENS_SPENT_RESPONSE) as TOKENS_SPENT_RESPONSE_AVG_STATE,
    minState(TOKENS_SPENT_RESPONSE) as TOKENS_SPENT_RESPONSE_MIN_STATE,
    maxState(TOKENS_SPENT_RESPONSE) as TOKENS_SPENT_RESPONSE_MAX_STATE,
    
    -- Cost calculation
    sumState(TOKENS_SPENT_PROMPT * a.inputCost + TOKENS_SPENT_RESPONSE * a.outputCost) as COST_TOTAL_STATE,
    avgState(TOKENS_SPENT_PROMPT * a.inputCost + TOKENS_SPENT_RESPONSE * a.outputCost) as COST_AVG_STATE,
    minState(TOKENS_SPENT_PROMPT * a.inputCost + TOKENS_SPENT_RESPONSE * a.outputCost) as COST_MIN_STATE,
    maxState(TOKENS_SPENT_PROMPT * a.inputCost + TOKENS_SPENT_RESPONSE * a.outputCost) as COST_MAX_STATE,
    
    -- Language metrics
    groupUniqArrayState(LANG_PROMPT) as LANG_PROMPT_STATE,
    groupUniqArrayState(LANG_RESPONSE) as LANG_RESPONSE_STATE,
    
    -- Sentiment metrics
    groupUniqArrayState(SENTIMENT_PROMPT) as SENTIMENT_PROMPT_STATE,
    groupUniqArrayState(SENTIMENT_RESPONSE) as SENTIMENT_RESPONSE_STATE,
    maxState(SENTIMENT_PROMPT_POSITIVE) as SENTIMENT_PROMPT_POSITIVE_MAX_STATE,
    maxState(SENTIMENT_PROMPT_NEGATIVE) as SENTIMENT_PROMPT_NEGATIVE_MAX_STATE,
    maxState(SENTIMENT_PROMPT_NEUTRAL) as SENTIMENT_PROMPT_NEUTRAL_MAX_STATE,
    maxState(SENTIMENT_RESPONSE_POSITIVE) as SENTIMENT_RESPONSE_POSITIVE_MAX_STATE,
    maxState(SENTIMENT_RESPONSE_NEGATIVE) as SENTIMENT_RESPONSE_NEGATIVE_MAX_STATE,
    maxState(SENTIMENT_RESPONSE_NEUTRAL) as SENTIMENT_RESPONSE_NEUTRAL_MAX_STATE,
    
    -- Readability metrics
    avgState(READABILITY_RESPONSE) as READABILITY_RESPONSE_AVG_STATE,
    
    -- Sample content (first message)
    argMinState(INPUT, START_TIMESTAMP) as FIRST_INPUT_STATE,
    argMinState(OUTPUT, START_TIMESTAMP) as FIRST_OUTPUT_STATE,
    
    -- Store OUTPUT_CLASSIFIERS as array of strings
    groupArrayState(OUTPUT_CLASSIFIERS) as OUTPUT_CLASSIFIERS_STATE
FROM traces_processed tp
JOIN apps a ON tp.APP_ID = a.id
WHERE TASK = 'message'
GROUP BY APP_ID, CONVERSATION_ID, EVENT_DATE, toStartOfDay(START_TIME);


-- Create a view to read from the materialized view
CREATE OR REPLACE VIEW traces_conversations_view AS
SELECT
    APP_ID,
    CONVERSATION_ID,
    -- Use minMerge and maxMerge to get the true first and last timestamps
    minMerge(MIN_START_TIMESTAMP_STATE) as FIRST_MESSAGE_TIMESTAMP,
    maxMerge(MAX_END_TIMESTAMP_STATE) as LAST_MESSAGE_TIMESTAMP,
    argMaxMerge(USER_ID_STATE) as USER_ID,
    argMaxMerge(SESSION_ID_STATE) as SESSION_ID,
    argMaxMerge(DEVICE_STATE) as DEVICE,
    argMaxMerge(OS_STATE) as OS,
    argMaxMerge(BROWSER_STATE) as BROWSER,
    argMaxMerge(LOCALE_STATE) as LOCALE,
    argMaxMerge(LOCATION_STATE) as LOCATION,
    argMaxMerge(CHANNEL_ID_STATE) as CHANNEL_ID,
    
    -- Conversation metrics
    countMerge(DIALOGUE_VOLUME_STATE) as DIALOGUE_VOLUME,
    if(countMerge(DIALOGUE_VOLUME_STATE) = 1, 1, 0) as ONE_INTERACTION,
    
    -- Time metrics - calculate directly from the timestamps
    (maxMerge(MAX_END_TIMESTAMP_STATE) - minMerge(MIN_START_TIMESTAMP_STATE))/1000/60 as TIME_TOTAL,
    if(countMerge(DIALOGUE_VOLUME_STATE) > 1, 
       ((maxMerge(MAX_END_TIMESTAMP_STATE) - minMerge(MIN_START_TIMESTAMP_STATE))/1000)/(countMerge(DIALOGUE_VOLUME_STATE)-1), 
       0) as TIME_BETWEEN_INTERACTIONS,
    
    -- Content metrics
    sumMerge(NUM_WORDS_PROMPT_TOTAL_STATE) as NUM_WORDS_PROMPT_TOTAL,
    avgMerge(NUM_WORDS_PROMPT_AVG_STATE) as NUM_WORDS_PROMPT_AVG,
    minMerge(NUM_WORDS_PROMPT_MIN_STATE) as NUM_WORDS_PROMPT_MIN,
    maxMerge(NUM_WORDS_PROMPT_MAX_STATE) as NUM_WORDS_PROMPT_MAX,
    
    sumMerge(NUM_WORDS_RESPONSE_TOTAL_STATE) as NUM_WORDS_RESPONSE_TOTAL,
    avgMerge(NUM_WORDS_RESPONSE_AVG_STATE) as NUM_WORDS_RESPONSE_AVG,
    minMerge(NUM_WORDS_RESPONSE_MIN_STATE) as NUM_WORDS_RESPONSE_MIN,
    maxMerge(NUM_WORDS_RESPONSE_MAX_STATE) as NUM_WORDS_RESPONSE_MAX,
    
    -- Latency metrics
    sumMerge(TIME_LATENCY_SUM_STATE) as TIME_LATENCY_SUM,
    avgMerge(TIME_LATENCY_AVG_STATE) as TIME_LATENCY_AVG,
    minMerge(TIME_LATENCY_MIN_STATE) as TIME_LATENCY_MIN,
    maxMerge(TIME_LATENCY_MAX_STATE) as TIME_LATENCY_MAX,
    
    -- Token metrics
    sumMerge(TOKENS_SPENT_PROMPT_TOTAL_STATE) as TOKENS_SPENT_PROMPT_TOTAL,
    avgMerge(TOKENS_SPENT_PROMPT_AVG_STATE) as TOKENS_SPENT_PROMPT_AVG,
    minMerge(TOKENS_SPENT_PROMPT_MIN_STATE) as TOKENS_SPENT_PROMPT_MIN,
    maxMerge(TOKENS_SPENT_PROMPT_MAX_STATE) as TOKENS_SPENT_PROMPT_MAX,
    
    sumMerge(TOKENS_SPENT_RESPONSE_TOTAL_STATE) as TOKENS_SPENT_RESPONSE_TOTAL,
    avgMerge(TOKENS_SPENT_RESPONSE_AVG_STATE) as TOKENS_SPENT_RESPONSE_AVG,
    minMerge(TOKENS_SPENT_RESPONSE_MIN_STATE) as TOKENS_SPENT_RESPONSE_MIN,
    maxMerge(TOKENS_SPENT_RESPONSE_MAX_STATE) as TOKENS_SPENT_RESPONSE_MAX,
    
    -- Cost metrics
    sumMerge(COST_TOTAL_STATE) as COST_TOTAL,
    avgMerge(COST_AVG_STATE) as COST_AVG,
    minMerge(COST_MIN_STATE) as COST_MIN,
    maxMerge(COST_MAX_STATE) as COST_MAX,
    
    -- Language metrics
    groupUniqArrayMerge(LANG_PROMPT_STATE) as LANG_PROMPT,
    groupUniqArrayMerge(LANG_RESPONSE_STATE) as LANG_RESPONSE,
    
    -- Sentiment metrics
    groupUniqArrayMerge(SENTIMENT_PROMPT_STATE) as SENTIMENT_PROMPT,
    groupUniqArrayMerge(SENTIMENT_RESPONSE_STATE) as SENTIMENT_RESPONSE,
    maxMerge(SENTIMENT_PROMPT_POSITIVE_MAX_STATE) as SENTIMENT_PROMPT_POSITIVE_MAX,
    maxMerge(SENTIMENT_PROMPT_NEGATIVE_MAX_STATE) as SENTIMENT_PROMPT_NEGATIVE_MAX,
    maxMerge(SENTIMENT_PROMPT_NEUTRAL_MAX_STATE) as SENTIMENT_PROMPT_NEUTRAL_MAX,
    maxMerge(SENTIMENT_RESPONSE_POSITIVE_MAX_STATE) as SENTIMENT_RESPONSE_POSITIVE_MAX,
    maxMerge(SENTIMENT_RESPONSE_NEGATIVE_MAX_STATE) as SENTIMENT_RESPONSE_NEGATIVE_MAX,
    maxMerge(SENTIMENT_RESPONSE_NEUTRAL_MAX_STATE) as SENTIMENT_RESPONSE_NEUTRAL_MAX,
    
    -- Readability metrics
    avgMerge(READABILITY_RESPONSE_AVG_STATE) as READABILITY_RESPONSE,
    
    -- Sample content
    argMinMerge(FIRST_INPUT_STATE) as FIRST_INPUT,
    argMinMerge(FIRST_OUTPUT_STATE) as FIRST_OUTPUT,
    
    -- Add timestamp fields converted to DateTime for easier querying
    fromUnixTimestamp64Milli(minMerge(MIN_START_TIMESTAMP_STATE)) as FIRST_MESSAGE_TIME,
    fromUnixTimestamp64Milli(maxMerge(MAX_END_TIMESTAMP_STATE)) as LAST_MESSAGE_TIME,

    -- Merge OUTPUT_CLASSIFIERS arrays and join them into a JSON array string
    concat('[', arrayStringConcat(groupArrayMerge(OUTPUT_CLASSIFIERS_STATE), ','), ']') as OUTPUT_CLASSIFIERS
FROM traces_conversations
GROUP BY APP_ID, CONVERSATION_ID;

-- Daily metrics for UI graphs (main materialized view)
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_usage_metrics
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    -- Message and conversation counts
    uniqState(INTERACTION_ID) as messages_count_state,
    uniqState(CONVERSATION_ID) as conversations_count_state,
    -- Timestamp metrics for calculating dialogue time
    minState(START_TIMESTAMP) as min_start_timestamp_state,
    maxState(END_TIMESTAMP) as max_end_timestamp_state,
    -- Word count metrics
    avgState(NUM_WORDS_PROMPT) as avg_prompt_words_state,
    avgState(NUM_WORDS_RESPONSE) as avg_response_words_state,
    -- Token metrics
    sumState(TOKENS_SPENT_PROMPT) as prompt_tokens_state,
    sumState(TOKENS_SPENT_RESPONSE) as response_tokens_state,
    avgState(TOKENS_SPENT_PROMPT) as avg_prompt_tokens_state,
    avgState(TOKENS_SPENT_RESPONSE) as avg_response_tokens_state,
    sumState(TOKENS_SPENT_PROMPT * a.inputCost) as prompt_cost_state,
    sumState(TOKENS_SPENT_RESPONSE * a.outputCost) as response_cost_state,
    sumState(TOKENS_SPENT_PROMPT * a.inputCost + TOKENS_SPENT_RESPONSE * a.outputCost) as total_cost_state,
    avgState(LATENCY) as avg_latency_state,
    -- Fix sentiment metrics to count each message only once for each sentiment type
    uniqStateIf(INTERACTION_ID, SENTIMENT_PROMPT_POSITIVE > 0.5) as sentiment_prompt_positive_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_PROMPT_NEGATIVE > 0.5) as sentiment_prompt_negative_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_RESPONSE_POSITIVE > 0.5) as sentiment_response_positive_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_RESPONSE_NEGATIVE > 0.5) as sentiment_response_negative_state,
    -- Readability metrics
    avgState(READABILITY_RESPONSE) as readability_response_state,
    -- Feedback metrics
    uniqStateIf(INTERACTION_ID, FEEDBACK_TAG = 'positive') as feedback_positive_count_state,
    uniqStateIf(INTERACTION_ID, FEEDBACK_TAG = 'negative') as feedback_negative_count_state
FROM traces_processed
JOIN apps a ON traces_processed.APP_ID = a.id
WHERE TASK = 'message'
GROUP BY APP_ID, EVENT_DATE, day;

-- Language metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_language_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, LANG_PROMPT, day)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    LANG_PROMPT,
    count() as language_count
FROM traces_processed
WHERE TASK = 'message'
GROUP BY APP_ID, EVENT_DATE, day, LANG_PROMPT;

-- Create a view to calculate conversation message counts
CREATE VIEW IF NOT EXISTS conversation_message_counts AS
SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    CONVERSATION_ID,
    count() as message_count
FROM traces_processed
WHERE TASK = 'message'
GROUP BY APP_ID, EVENT_DATE, day, CONVERSATION_ID;

-- Create a view to calculate single message rate
CREATE VIEW IF NOT EXISTS single_message_rate_view AS
SELECT
    APP_ID,
    EVENT_DATE,
    day,
    countIf(message_count = 1) as single_message_conversations,
    count() as total_conversations,
    100.0 * countIf(message_count = 1) / count() as single_message_rate
FROM conversation_message_counts
GROUP BY APP_ID, EVENT_DATE, day;

-- User and session metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_user_metrics
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    -- User metrics
    uniqState(USER_ID) as users_count_state,
    uniqState(if(is_first_time, USER_ID, null)) as new_users_count_state,
    -- Session metrics
    uniqState(SESSION_ID) as sessions_count_state,
    -- Location metrics
    uniqState(LOCATION) as countries_count_state,
    groupArrayState(LOCATION) as countries_state
FROM (
    SELECT 
        APP_ID,
        START_TIME,
        EVENT_DATE,
        USER_ID,
        SESSION_ID,
        LOCATION,
        -- Determine if this is the user's first interaction
        min(START_TIMESTAMP) OVER (PARTITION BY APP_ID, USER_ID) = START_TIMESTAMP as is_first_time
    FROM traces_processed
    WHERE TASK = 'message' AND USER_ID != ''
)
GROUP BY APP_ID, EVENT_DATE, day;

-- Create a view for metrics analysis
CREATE OR REPLACE VIEW traces_metrics AS
SELECT
    m.APP_ID AS APP_ID,
    m.EVENT_DATE AS EVENT_DATE,
    m.day AS day,
    -- Basic metrics
    uniqMerge(m.messages_count_state) AS messages_count,
    uniqMerge(m.conversations_count_state) AS conversations_count,
    -- Calculated metrics
    uniqMerge(m.messages_count_state) / uniqMerge(m.conversations_count_state) as dialogue_volume,
    
    avgMerge(m.avg_prompt_words_state) as avg_prompt_words,
    avgMerge(m.avg_response_words_state) as avg_response_words,
    -- Token metrics
    sumMerge(m.prompt_tokens_state) as prompt_tokens,
    sumMerge(m.response_tokens_state) as response_tokens,
    -- Tokens per message metrics
    avgMerge(m.avg_prompt_tokens_state) as avg_prompt_tokens,
    avgMerge(m.avg_response_tokens_state) as avg_response_tokens,
    
    avgMerge(m.avg_latency_state) as avg_latency,

    -- Cost calculation
    sumMerge(m.prompt_cost_state) as prompt_cost,
    sumMerge(m.response_cost_state) as response_cost,
    sumMerge(m.total_cost_state) as total_cost,
    -- User metrics
    uniqMerge(u.users_count_state) as users_count,
    uniqMerge(u.new_users_count_state) as new_users_count,
    -- Session metrics
    uniqMerge(u.sessions_count_state) as sessions_count,
    -- Calculate sessions per user
    if(uniqMerge(u.users_count_state) > 0, 
       uniqMerge(u.sessions_count_state) / uniqMerge(u.users_count_state), 
       0) as sessions_per_user,
    
    -- Sentiment metrics
    uniqMerge(m.sentiment_prompt_positive_state) AS sentiment_prompt_positive,
    uniqMerge(m.sentiment_prompt_negative_state) AS sentiment_prompt_negative,
    uniqMerge(m.sentiment_response_positive_state) AS sentiment_response_positive,
    uniqMerge(m.sentiment_response_negative_state) AS sentiment_response_negative,
    
    -- Sentiment rate metrics (percentage of messages with positive/negative sentiment)
    100.0 * uniqMerge(m.sentiment_prompt_positive_state) / uniqMerge(m.messages_count_state) as sentiment_prompt_positive_rate,
    100.0 * uniqMerge(m.sentiment_prompt_negative_state) / uniqMerge(m.messages_count_state) as sentiment_prompt_negative_rate,
    100.0 * uniqMerge(m.sentiment_response_positive_state) / uniqMerge(m.messages_count_state) as sentiment_response_positive_rate,
    100.0 * uniqMerge(m.sentiment_response_negative_state) / uniqMerge(m.messages_count_state) as sentiment_response_negative_rate,
    
    -- Readability metrics
    avgMerge(m.readability_response_state) as readability,
    
    -- Feedback metrics
    uniqMerge(m.feedback_positive_count_state) as feedback_positive,
    uniqMerge(m.feedback_negative_count_state) as feedback_negative,
    100.0 * uniqMerge(m.feedback_positive_count_state) / uniqMerge(m.messages_count_state) as feedback_positive_rate,
    100.0 * uniqMerge(m.feedback_negative_count_state) / uniqMerge(m.messages_count_state) as feedback_negative_rate
FROM traces_usage_metrics m
LEFT JOIN traces_user_metrics u ON m.APP_ID = u.APP_ID AND m.EVENT_DATE = u.EVENT_DATE AND m.day = u.day
GROUP BY m.APP_ID, m.EVENT_DATE, m.day;

-- Create a view for country metrics
CREATE OR REPLACE VIEW traces_country_metrics AS
    SELECT
        APP_ID,
        EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    LOCATION as country,
    count() as count
FROM traces_processed
WHERE TASK = 'message' AND LOCATION != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), LOCATION
ORDER BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), count DESC;

-- Update the total metrics view to include READABILITY metrics
CREATE OR REPLACE VIEW traces_metrics_total AS
SELECT
    m.APP_ID,
    sum(m.messages_count) as total_messages,
    sum(m.conversations_count) as total_conversations,
    avg(m.dialogue_volume) as avg_dialogue_volume,
    avg(m.avg_prompt_words) as avg_prompt_words,
    avg(m.avg_response_words) as avg_response_words,
    -- Token metrics
    sum(m.prompt_tokens) as total_prompt_tokens,
    sum(m.response_tokens) as total_response_tokens,
    avg(m.avg_latency) as avg_latency,
    -- Cost calculation
    sum(m.prompt_cost) as prompt_cost,
    sum(m.response_cost) as response_cost,
    sum(m.total_cost) as total_cost,
    -- User metrics
    sum(m.users_count) as total_users,
    sum(m.new_users_count) as total_new_users,
    -- Session metrics
    sum(m.sessions_count) as total_sessions,
    avg(m.sessions_per_user) as avg_sessions_per_user,
    -- Sentiment metrics
    avg(m.sentiment_prompt_positive) as sentiment_prompt_positive,
    avg(m.sentiment_prompt_negative) as sentiment_prompt_negative,
    avg(m.sentiment_response_positive) as sentiment_response_positive,
    avg(m.sentiment_response_negative) as sentiment_response_negative,
    -- Readability metrics
    avg(m.readability) as readability,
    -- Feedback metrics
    avg(m.feedback_positive_rate) as feedback_positive_rate,
    avg(m.feedback_negative_rate) as feedback_negative_rate
FROM traces_metrics m
GROUP BY m.APP_ID;

-- Separate language metrics view
CREATE VIEW IF NOT EXISTS traces_language_daily AS
SELECT
    APP_ID,
    EVENT_DATE,
    day,
    LANG_PROMPT as language,
    sum(language_count) as count
FROM traces_language_metrics
GROUP BY APP_ID, EVENT_DATE, day, LANG_PROMPT
ORDER BY APP_ID, EVENT_DATE, day, count DESC;

-- Device metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_device_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, DEVICE)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    DEVICE,
    count(DISTINCT SESSION_ID) as count
FROM traces_processed
WHERE TASK = 'message' AND DEVICE != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), DEVICE;

-- Browser metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_browser_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, BROWSER)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    BROWSER,
    count(DISTINCT SESSION_ID) as count
FROM traces_processed
WHERE TASK = 'message' AND BROWSER != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), BROWSER;

-- OS metrics view
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_os_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, OS)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    OS,
    count(DISTINCT SESSION_ID) as count
FROM traces_processed
WHERE TASK = 'message' AND OS != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), OS;

-- Create a materialized view for sessions by channel
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_channel_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, channel)
AS
SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    CHANNEL_ID as channel,
    count(DISTINCT SESSION_ID) as count
FROM traces_processed
WHERE TASK = 'message' AND CHANNEL_ID IS NOT NULL
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), CHANNEL_ID;

-- First, create a materialized view to collect user engagement data
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_user_engagement_data
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, USER_ID)
AS SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    USER_ID,
    -- Count interactions per user
    count() as interaction_count
FROM traces_processed
WHERE TASK = 'message' AND USER_ID != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), USER_ID;

-- Then create a regular view on top of the materialized view
CREATE OR REPLACE VIEW traces_engagement_metrics AS
    SELECT
        APP_ID,
        EVENT_DATE,
        day,
        -- User metrics
        uniqExact(USER_ID) as active_users,
        -- Average calls per user
        sum(interaction_count) / uniqExact(USER_ID) as avg_calls_per_user,
        -- Maximum calls per user
        max(interaction_count) as max_calls_per_user
FROM traces_user_engagement_data
GROUP BY APP_ID, EVENT_DATE, day;

-- Top users by requests view with AggregatingMergeTree engine
CREATE MATERIALIZED VIEW IF NOT EXISTS traces_top_users
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(EVENT_DATE)
ORDER BY (EVENT_DATE, APP_ID, day, USER_ID)
AS 
SELECT
    APP_ID,
    EVENT_DATE,
    toStartOfDay(START_TIME) as day,
    USER_ID,
    countState() as request_count_state
FROM traces_processed
WHERE TASK = 'message' AND USER_ID != ''
GROUP BY APP_ID, EVENT_DATE, toStartOfDay(START_TIME), USER_ID;

-- Create a materialized view for daily classifier KPIs
CREATE MATERIALIZED VIEW IF NOT EXISTS kpi_topics_1d
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (day, APP_ID, CLASSIFIER_ID, CATEGORY_ID, LABEL_ID)
AS SELECT
    toDate(toStartOfDay(START_TIME)) AS day,
    APP_ID,
    CLASSIFIER_ID,
    CATEGORY_ID,
    LABEL_ID,
    SCORE,
    
    -- Conversation and message counts
    uniqState(CONVERSATION_ID) AS conversations_count_state,
    uniqState(INTERACTION_ID) AS messages_count_state,
    
    -- Sentiment metrics
    uniqStateIf(INTERACTION_ID, SENTIMENT_PROMPT_POSITIVE > 0) AS sentiment_prompt_positive_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_PROMPT_NEGATIVE > 0) AS sentiment_prompt_negative_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_RESPONSE_POSITIVE > 0) AS sentiment_response_positive_state,
    uniqStateIf(INTERACTION_ID, SENTIMENT_RESPONSE_NEGATIVE > 0) AS sentiment_response_negative_state,
    
    -- Language metrics
    countState(LANG_PROMPT) AS lang_prompt_count_state,
    countState(LANG_RESPONSE) AS lang_response_count_state,
    
    -- Word count metrics
    sumState(NUM_WORDS_PROMPT) AS num_words_prompt_state,
    sumState(NUM_WORDS_RESPONSE) AS num_words_response_state,
    
    -- Token metrics
    sumState(TOKENS_SPENT_PROMPT) AS tokens_spent_prompt_state,
    sumState(TOKENS_SPENT_RESPONSE) AS tokens_spent_response_state,
    
    -- Readability metrics
    avgState(READABILITY_RESPONSE) AS readability_response_state,
    
    -- Cost metrics - store tokens for later calculation with app costs
    sumState(TOKENS_SPENT_PROMPT) AS cost_prompt_state,
    sumState(TOKENS_SPENT_RESPONSE) AS cost_response_state,
    
    -- Time metrics
    avgState(LATENCY) AS time_latency_state,
    
    -- Dialogue time metrics
    minState(START_TIME) AS min_start_time_state,
    maxState(END_TIMESTAMP) AS max_end_time_state,
    uniqState(INTERACTION_ID) AS dialogue_volume_state,
    
    -- Feedback metrics
    uniqStateIf(INTERACTION_ID, FEEDBACK_TAG = 'positive') as feedback_positive_count_state,
    uniqStateIf(INTERACTION_ID, FEEDBACK_TAG = 'negative') as feedback_negative_count_state,
    
    -- Conversation duration - first calculate per conversation then average
    avgState(conversation_duration) AS conversation_duration_state
FROM (
    -- First get duration per conversation
    SELECT 
        *,
        (max(END_TIMESTAMP) OVER (PARTITION BY APP_ID, CONVERSATION_ID) - 
         min(START_TIMESTAMP) OVER (PARTITION BY APP_ID, CONVERSATION_ID)) / 1000 / 60 as conversation_duration
    FROM (
        SELECT
            APP_ID,
            START_TIME,
            START_TIMESTAMP,
            END_TIMESTAMP,
            CONVERSATION_ID,
            INTERACTION_ID,
            EVENT_DATE,
            SENTIMENT_PROMPT_POSITIVE,
            SENTIMENT_PROMPT_NEGATIVE,
            SENTIMENT_PROMPT_NEUTRAL,
            SENTIMENT_RESPONSE_POSITIVE,
            SENTIMENT_RESPONSE_NEGATIVE,
            SENTIMENT_RESPONSE_NEUTRAL,
            LANG_PROMPT,
            LANG_RESPONSE,
            NUM_WORDS_PROMPT,
            NUM_WORDS_RESPONSE,
            TOKENS_SPENT_PROMPT,
            TOKENS_SPENT_RESPONSE,
            READABILITY_RESPONSE,
            LATENCY,
            FEEDBACK_TAG,
            JSONExtractInt(json, 'ID') AS CLASSIFIER_ID,
            JSONExtractString(json, 'CATEGORY') AS CATEGORY_ID,
            JSONExtractString(label) AS LABEL_ID,
            JSONExtractInt(json, 'SCORE') AS SCORE
        FROM traces_processed
        ARRAY JOIN JSONExtractArrayRaw(OUTPUT_CLASSIFIERS) AS json
        ARRAY JOIN JSONExtractArrayRaw(json, 'LABEL') AS label
        WHERE OUTPUT_CLASSIFIERS IS NOT NULL AND OUTPUT_CLASSIFIERS != '' AND TASK = 'message'
    )
)
GROUP BY day, APP_ID, CLASSIFIER_ID, CATEGORY_ID, LABEL_ID, SCORE;

-- Create a view for querying the aggregated data with app costs
CREATE OR REPLACE VIEW kpi_topics_1d_view AS
SELECT
    k.day,
    k.APP_ID,
    k.CLASSIFIER_ID,
    k.CATEGORY_ID,
    k.LABEL_ID,
    
    -- Average conversation duration in minutes for this topic
    avgMerge(k.conversation_duration_state) AS TIME_TOTAL,
    
    -- Cost calculation using app costs (default to 0 if NULL)
    sumMerge(k.cost_prompt_state) * if(a.inputCost IS NULL, 0, a.inputCost) + 
    sumMerge(k.cost_response_state) * if(a.outputCost IS NULL, 0, a.outputCost) AS COST,
    
    -- Conversation and message counts
    uniqMerge(k.conversations_count_state) AS CONVERSATIONS,
    uniqMerge(k.messages_count_state) AS MESSAGES,
    uniqMerge(k.messages_count_state) / uniqMerge(k.conversations_count_state) AS DIALOGUE_VOLUME,
    
    -- Sentiment metrics
    if(isNull(100.0 * uniqMerge(k.sentiment_prompt_positive_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)),
        0,
        100.0 * uniqMerge(k.sentiment_prompt_positive_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)) AS SENTIMENT_PROMPT_POSITIVE,
    
    if(isNull(100.0 * uniqMerge(k.sentiment_prompt_negative_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)),
        0,
        100.0 * uniqMerge(k.sentiment_prompt_negative_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)) AS SENTIMENT_PROMPT_NEGATIVE,
    
    if(isNull(100.0 * uniqMerge(k.sentiment_response_positive_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)),
        0,
        100.0 * uniqMerge(k.sentiment_response_positive_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)) AS SENTIMENT_RESPONSE_POSITIVE,
    
    if(isNull(100.0 * uniqMerge(k.sentiment_response_negative_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)),
        0,
        100.0 * uniqMerge(k.sentiment_response_negative_state) / 
        nullIf(uniqMerge(k.messages_count_state), 0)) AS SENTIMENT_RESPONSE_NEGATIVE,
    
    -- Sentiment rate metrics
    100.0 * uniqMerge(k.sentiment_prompt_positive_state) / uniqMerge(k.messages_count_state) as SENTIMENT_PROMPT_POSITIVE_RATE,
    100.0 * uniqMerge(k.sentiment_prompt_negative_state) / uniqMerge(k.messages_count_state) as SENTIMENT_PROMPT_NEGATIVE_RATE,
    100.0 * uniqMerge(k.sentiment_response_positive_state) / uniqMerge(k.messages_count_state) as SENTIMENT_RESPONSE_POSITIVE_RATE,
    100.0 * uniqMerge(k.sentiment_response_negative_state) / uniqMerge(k.messages_count_state) as SENTIMENT_RESPONSE_NEGATIVE_RATE,
    
    -- Language metrics
    countMerge(k.lang_prompt_count_state) AS LANG_PROMPT,
    countMerge(k.lang_response_count_state) AS LANG_RESPONSE,
    
    
    -- Word count metrics
    sumMerge(k.num_words_prompt_state) AS NUM_WORDS_PROMPT,
    sumMerge(k.num_words_response_state) AS NUM_WORDS_RESPONSE,
    
    -- Token metrics
    sumMerge(k.tokens_spent_prompt_state) AS TOKENS_SPENT_PROMPT,
    sumMerge(k.tokens_spent_response_state) AS TOKENS_SPENT_RESPONSE,
    
    -- Readability metrics
    avgMerge(k.readability_response_state) AS READABILITY_RESPONSE,
    
    -- Time metrics
    avgMerge(k.time_latency_state) AS TIME_LATENCY,
    
    -- Feedback metrics
    uniqMerge(k.feedback_positive_count_state) as FEEDBACK_POSITIVE,
    uniqMerge(k.feedback_negative_count_state) as FEEDBACK_NEGATIVE,
    100.0 * uniqMerge(k.feedback_positive_count_state) / uniqMerge(k.messages_count_state) as FEEDBACK_POSITIVE_RATE,
    100.0 * uniqMerge(k.feedback_negative_count_state) / uniqMerge(k.messages_count_state) as FEEDBACK_NEGATIVE_RATE
FROM kpi_topics_1d k
LEFT JOIN apps a ON k.APP_ID = a.id
GROUP BY k.day, k.APP_ID, k.CLASSIFIER_ID, k.CATEGORY_ID, k.LABEL_ID, a.inputCost, a.outputCost;

-- ============================================================================
-- NEURALTRUST CLICKHOUSE SCHEMA - FULLY AUTOMATED
-- ============================================================================
-- All tables are auto-populated from traces/spans via materialized views
-- No external scripts needed!

-- ============================================================================
-- BASE TABLES (Written by Kafka Connect)
-- ============================================================================

-- Raw staging table - Kafka Connect writes JSON string here
-- ClickHouse parses it via materialized views (fastest and most reliable)
CREATE TABLE IF NOT EXISTS neuraltrust.agent_traces (
    raw_json String,
    ingested_at DateTime64(6, 'UTC') DEFAULT now64(6),
    ingested_date Date MATERIALIZED toDate(ingested_at)
)
ENGINE = MergeTree()
ORDER BY ingested_at
TTL ingested_date + INTERVAL 7 DAY;

-- ============================================================================
-- DOMAIN TABLES (Auto-populated via Materialized Views)
-- ============================================================================

-- 1. AGENTS - Core agent registry
CREATE TABLE IF NOT EXISTS neuraltrust.agents (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    agent_id String,
    agent_name String,
    framework String,  -- LangChain, CrewAI, AutoGen, LangGraph
    policy_role String,
    risk_level Enum8('Low' = 1, 'Medium' = 2, 'High' = 3),
    status Enum8('Active' = 1, 'Disabled' = 2, 'Quarantined' = 3),
    metadata String,  -- JSON string for additional properties
    first_seen DateTime64(6, 'UTC'),
    last_activity DateTime64(6, 'UTC'),
    updated_at DateTime64(6, 'UTC') DEFAULT now64(6)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (team_id, agent_id)
PRIMARY KEY (team_id, agent_id);

-- 2. TOOLS - Tool catalog
CREATE TABLE IF NOT EXISTS neuraltrust.tools (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    tool_id String,
    tool_name String,
    tool_category String,  -- Slack, Email, Database, API Gateway, etc.
    tool_action String,  -- read_messages, send_email, write_data, etc.
    description String,
    first_seen DateTime64(6, 'UTC'),
    updated_at DateTime64(6, 'UTC') DEFAULT now64(6)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (team_id, tool_id)
PRIMARY KEY (team_id, tool_id);

-- 3. AGENT_TOOL_PERMISSIONS - Which tools each agent can use
CREATE TABLE IF NOT EXISTS neuraltrust.agent_tool_permissions (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    agent_id String,
    tool_id String,
    tool_name String,
    tool_category String,
    tool_action String,
    approved Bool DEFAULT false,
    approved_at DateTime64(6, 'UTC'),
    first_requested DateTime64(6, 'UTC'),
    last_requested DateTime64(6, 'UTC'),
    updated_at DateTime64(6, 'UTC') DEFAULT now64(6)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (team_id, agent_id, tool_id)
PRIMARY KEY (team_id, agent_id, tool_id);

-- 4. TOOL_REQUESTS - Log of all tool invocations (for metrics)
CREATE TABLE IF NOT EXISTS neuraltrust.tool_requests (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    request_id String,
    trace_id String,
    span_id String,
    agent_id String,
    tool_id String,
    tool_name String,
    tool_category String,
    tool_action String,
    status Enum8('success' = 1, 'error' = 2, 'blocked' = 3, 'pending' = 4),
    approved Bool,
    duration_ms Float64,
    request_params String,  -- JSON
    response_data String,   -- JSON
    error_message String,
    timestamp DateTime64(6, 'UTC'),
    date Date MATERIALIZED toDate(timestamp)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (team_id, agent_id, tool_id, timestamp)
TTL date + INTERVAL 90 DAY;

-- 4b. AGENT_REQUESTS - Log of all agent invocations (for full trace view)
CREATE TABLE IF NOT EXISTS neuraltrust.agent_requests (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    request_id String,
    trace_id String,
    span_id String,
    agent_id String,
    parent_agent_id String,  -- If called by another agent
    parent_span_id String,   -- Parent span for trace linking
    status Enum8('success' = 1, 'error' = 2, 'timeout' = 3, 'cancelled' = 4),
    duration_ms Float64,
    input_data String,  -- JSON - from LLM child span or agent attributes
    output_data String,  -- JSON - from LLM child span or agent attributes
    agent_tools String,  -- JSON array of available tools
    agent_output_type String,
    framework String,
    error_message String,
    timestamp DateTime64(6, 'UTC'),
    date Date MATERIALIZED toDate(timestamp)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (team_id, agent_id, timestamp)
TTL date + INTERVAL 90 DAY;

-- 5. AGENT_DEPENDENCIES - Agent-to-agent and agent-to-tool connections
CREATE TABLE IF NOT EXISTS neuraltrust.agent_dependencies (
    team_id String,    -- Multi-tenant: prevents ID collisions across teams
    source_agent_id String,
    target_type Enum8('agent' = 1, 'tool' = 2),
    target_id String,
    target_name String,
    dependency_type Enum8('calls' = 1, 'uses' = 2, 'monitors' = 3, 'processes' = 4),
    connection_count UInt64 DEFAULT 1,
    first_seen DateTime64(6, 'UTC'),
    last_seen DateTime64(6, 'UTC'),
    updated_at DateTime64(6, 'UTC') DEFAULT now64(6)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (team_id, source_agent_id, target_type, target_id)
PRIMARY KEY (team_id, source_agent_id, target_type, target_id);

-- 6. GUARDIAN_INVOCATIONS - Security/policy checks
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

-- ============================================================================
-- MATERIALIZED VIEWS (Auto-populate from agent_traces)
-- These parse OpenTelemetry trace format with nested spans
-- ============================================================================

-- MV1: Extract and populate agents from workflow spans
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_agents
TO neuraltrust.agents
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        JSONExtractString(raw_json, 'resource', 'library_name') as framework,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
spans_array AS (
    SELECT
        team_id,
        framework,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
)
SELECT
    team_id AS team_id,
    JSONExtractString(span_json, 'attributes', 'agent_name') AS agent_id,
    JSONExtractString(span_json, 'attributes', 'agent_name') AS agent_name,
    coalesce(framework, 'unknown') AS framework,
    'Assistant' AS policy_role,
    'Low' AS risk_level,
    'Active' AS status,
    '{}' AS metadata,
    ingested_at AS first_seen,
    ingested_at AS last_activity,
    ingested_at AS updated_at
FROM spans_array
WHERE JSONExtractString(span_json, 'kind') = 'workflow'
  AND JSONExtractString(span_json, 'attributes', 'agent_name') != '';

-- MV2: Extract and populate tools from tool spans
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_tools
TO neuraltrust.tools
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
spans_array AS (
    SELECT
        team_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
)
SELECT
    team_id AS team_id,
    JSONExtractString(span_json, 'attributes', 'function_name') AS tool_id,
    JSONExtractString(span_json, 'attributes', 'function_name') AS tool_name,
    'API' AS tool_category,
    'execute' AS tool_action,
    '' AS description,
    ingested_at AS first_seen,
    ingested_at AS updated_at
FROM spans_array
WHERE JSONExtractString(span_json, 'kind') = 'tool'
  AND JSONExtractString(span_json, 'attributes', 'function_name') != '';

-- MV3: Extract agent-tool permissions from tool usage
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_permissions
TO neuraltrust.agent_tool_permissions
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
traces_data AS (
    SELECT
        team_id,
        JSONExtractString(trace_json, 'trace_id') as trace_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
),
tool_spans AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        JSONExtractString(span_json, 'attributes', 'function_name') as tool_name,
        JSONExtractString(span_json, 'status') as status,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'tool'
),
parent_agents AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'attributes', 'agent_name') as agent_name
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'workflow'
)
SELECT
    p.team_id AS team_id,
    t.agent_name AS agent_id,
    p.tool_name AS tool_id,
    p.tool_name AS tool_name,
    'API' AS tool_category,
    'execute' AS tool_action,
    true AS approved,
    p.ingested_at AS approved_at,
    p.ingested_at AS first_requested,
    p.ingested_at AS last_requested,
    p.ingested_at AS updated_at
FROM tool_spans p
JOIN parent_agents t ON p.parent_id = t.span_id AND p.trace_id = t.trace_id AND p.team_id = t.team_id
WHERE p.tool_name != '' AND t.agent_name != '';

-- Updated materialized views MV4, MV5, MV6 with team_id support
-- Replace the existing MV4, MV5, MV6 in clickhouse_schema_final.sql with these

-- MV4: Extract tool requests/invocations
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_tool_requests
TO neuraltrust.tool_requests
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
traces_data AS (
    SELECT
        team_id,
        JSONExtractString(trace_json, 'trace_id') as trace_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
),
tool_spans AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        JSONExtractString(span_json, 'name') as tool_name,
        JSONExtractString(span_json, 'attributes', 'function_name') as function_name,
        JSONExtractString(span_json, 'attributes', 'input') as input,
        JSONExtractString(span_json, 'attributes', 'output') as output,
        JSONExtractString(span_json, 'status') as status,
        JSONExtractFloat(span_json, 'started_at') as started_at,
        JSONExtractFloat(span_json, 'ended_at') as ended_at,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'tool'
),
parent_agents AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'attributes', 'agent_name') as agent_name
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'workflow'
)
SELECT
    p.team_id AS team_id,
    p.span_id AS request_id,
    p.trace_id AS trace_id,
    p.span_id AS span_id,
    t.agent_name AS agent_id,
    coalesce(p.function_name, p.tool_name) AS tool_id,
    coalesce(p.function_name, p.tool_name) AS tool_name,
    'API' AS tool_category,
    'execute' AS tool_action,
    CASE 
        WHEN p.status = 'ok' AND position(p.output, 'error') = 0 THEN 'success'
        WHEN position(p.output, 'jailbreak') > 0 OR position(p.output, 'Error code: 403') > 0 THEN 'blocked'
        ELSE 'error'
    END AS status,
    CASE 
        WHEN position(p.output, 'jailbreak') > 0 OR position(p.output, 'Error code: 403') > 0 THEN false
        ELSE true
    END AS approved,
    (p.ended_at - p.started_at) * 1000 AS duration_ms,
    p.input AS request_params,
    p.output AS response_data,
    CASE 
        WHEN position(p.output, 'error') > 0 THEN p.output
        ELSE ''
    END AS error_message,
    p.ingested_at AS timestamp
FROM tool_spans p
JOIN parent_agents t ON p.parent_id = t.span_id AND p.trace_id = t.trace_id AND p.team_id = t.team_id
WHERE coalesce(p.function_name, p.tool_name) != '' AND t.agent_name != '';

-- MV5: Extract agent dependencies (agent-to-agent AND agent-to-tool)
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_dependencies
TO neuraltrust.agent_dependencies
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
traces_data AS (
    SELECT
        team_id,
        JSONExtractString(trace_json, 'trace_id') as trace_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
),
-- Agent-to-agent dependencies (handles direct and via tools)
all_agents AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        JSONExtractString(span_json, 'attributes', 'agent_name') as agent_name,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'workflow'
),
tool_spans_for_chain AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'tool'
),
-- Direct agent-to-agent relationships
agent_to_agent_direct AS (
    SELECT
        child.team_id AS team_id,
        parent.agent_name AS source_agent_id,
        child.agent_name AS target_id,
        child.ingested_at AS ingested_at
    FROM all_agents child
    JOIN all_agents parent ON child.parent_id = parent.span_id AND child.trace_id = parent.trace_id AND child.team_id = parent.team_id
    WHERE child.agent_name != parent.agent_name
),
-- Agent-to-agent via tool chain (orchestrator -> tool -> italian_agent)
agent_to_agent_via_tool AS (
    SELECT
        child.team_id AS team_id,
        grandparent.agent_name AS source_agent_id,
        child.agent_name AS target_id,
        child.ingested_at AS ingested_at
    FROM all_agents child
    JOIN tool_spans_for_chain tool ON child.parent_id = tool.span_id AND child.trace_id = tool.trace_id AND child.team_id = tool.team_id
    JOIN all_agents grandparent ON tool.parent_id = grandparent.span_id AND tool.trace_id = grandparent.trace_id AND tool.team_id = grandparent.team_id
    WHERE child.agent_name != grandparent.agent_name
),
-- Combine direct and via-tool agent relationships
agent_to_agent AS (
    SELECT
        team_id,
        source_agent_id,
        'agent' AS target_type,
        target_id,
        target_id AS target_name,
        'calls' AS dependency_type,
        ingested_at
    FROM agent_to_agent_direct
    UNION ALL
    SELECT
        team_id,
        source_agent_id,
        'agent' AS target_type,
        target_id,
        target_id AS target_name,
        'calls' AS dependency_type,
        ingested_at
    FROM agent_to_agent_via_tool
),
-- Agent-to-tool dependencies
tool_spans AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        coalesce(
            JSONExtractString(span_json, 'attributes', 'function_name'),
            JSONExtractString(span_json, 'name')
        ) as tool_name,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'tool'
),
agent_to_tool AS (
    SELECT
        p.team_id,
        t.agent_name AS source_agent_id,
        'tool' AS target_type,
        p.tool_name AS target_id,
        p.tool_name AS target_name,
        'uses' AS dependency_type,
        p.ingested_at
    FROM tool_spans p
    JOIN all_agents t ON p.parent_id = t.span_id AND p.trace_id = t.trace_id AND p.team_id = t.team_id
    WHERE p.tool_name != '' AND t.agent_name != ''
),
-- Combine both types
all_dependencies AS (
    SELECT * FROM agent_to_agent
    UNION ALL
    SELECT * FROM agent_to_tool
)
SELECT
    team_id AS team_id,
    source_agent_id AS source_agent_id,
    target_type AS target_type,
    target_id AS target_id,
    target_name AS target_name,
    dependency_type AS dependency_type,
    1 AS connection_count,
    min(ingested_at) AS first_seen,
    max(ingested_at) AS last_seen,
    max(ingested_at) AS updated_at
FROM all_dependencies
WHERE source_agent_id != '' AND target_id != ''
GROUP BY team_id, source_agent_id, target_type, target_id, target_name, dependency_type;

-- MV6: Extract guardian/security checks from blocked tool calls
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_guardian_invocations
TO neuraltrust.guardian_invocations
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
traces_data AS (
    SELECT
        team_id,
        JSONExtractString(trace_json, 'trace_id') as trace_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
),
tool_spans AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        JSONExtractString(span_json, 'attributes', 'function_name') as function_name,
        JSONExtractString(span_json, 'attributes', 'output') as output,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'tool'
      AND (position(JSONExtractString(span_json, 'attributes', 'output'), 'jailbreak') > 0
           OR position(JSONExtractString(span_json, 'attributes', 'output'), 'Error code: 403') > 0)
),
parent_agents AS (
    SELECT
        team_id,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'attributes', 'agent_name') as agent_name
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'workflow'
)
SELECT
    p.team_id AS team_id,
    concat('guard_', p.span_id) AS invocation_id,
    p.trace_id AS trace_id,
    t.agent_name AS agent_id,
    'jailbreak_detection' AS check_type,
    'blocked' AS result,
    CASE
        WHEN position(p.output, 'score 0.97') > 0 THEN 0.97
        WHEN position(p.output, 'score 0.95') > 0 THEN 0.95
        WHEN position(p.output, 'score 0.90') > 0 THEN 0.90
        ELSE 0.85
    END AS risk_score,
    substring(p.output, 1, 500) AS reason,
    concat('{"tool": "', p.function_name, '"}') AS metadata,
    p.ingested_at AS timestamp
FROM tool_spans p
JOIN parent_agents t ON p.parent_id = t.span_id AND p.trace_id = t.trace_id AND p.team_id = t.team_id
WHERE t.agent_name != '';

-- MV7: Extract agent requests/invocations for full trace view
CREATE MATERIALIZED VIEW IF NOT EXISTS neuraltrust.mv_populate_agent_requests
TO neuraltrust.agent_requests
AS
WITH traces_array AS (
    SELECT
        coalesce(JSONExtractString(raw_json, 'team_id'), JSONExtractString(raw_json, 'resource', 'team_id'), 'default') as team_id,
        JSONExtractString(raw_json, 'resource', 'library_name') as framework,
        arrayJoin(JSONExtractArrayRaw(raw_json, 'traces')) as trace_json,
        ingested_at
    FROM neuraltrust.agent_traces
),
traces_data AS (
    SELECT
        team_id,
        framework,
        JSONExtractString(trace_json, 'trace_id') as trace_id,
        arrayJoin(JSONExtractArrayRaw(trace_json, 'spans')) as span_json,
        ingested_at
    FROM traces_array
),
-- Extract agent workflow spans
agent_spans AS (
    SELECT
        team_id,
        framework,
        trace_id,
        JSONExtractString(span_json, 'id') as span_id,
        JSONExtractString(span_json, 'parent_id') as parent_id,
        JSONExtractString(span_json, 'attributes', 'agent_name') as agent_name,
        JSONExtractString(span_json, 'attributes', 'agent_tools') as agent_tools,
        JSONExtractString(span_json, 'attributes', 'agent_output_type') as agent_output_type,
        JSONExtractString(span_json, 'status') as status,
        JSONExtractFloat(span_json, 'started_at') as started_at,
        JSONExtractFloat(span_json, 'ended_at') as ended_at,
        ingested_at
    FROM traces_data
    WHERE JSONExtractString(span_json, 'kind') = 'workflow'
      AND JSONExtractString(span_json, 'attributes', 'agent_name') != ''
),
-- Find parent agent if called by another agent
parent_agent_info AS (
    SELECT
        a.team_id,
        a.trace_id,
        a.span_id,
        a.agent_name,
        a.parent_id,
        a.agent_tools,
        a.agent_output_type,
        a.status,
        a.started_at,
        a.ended_at,
        a.framework,
        a.ingested_at,
        parent.agent_name as parent_agent_name
    FROM agent_spans a
    LEFT JOIN agent_spans parent ON a.parent_id = parent.span_id 
        AND a.trace_id = parent.trace_id 
        AND a.team_id = parent.team_id
        AND parent.agent_name != ''
),
-- Extract LLM spans for input/output (child spans of agent)
-- Take first LLM span per agent to avoid duplicates
llm_spans AS (
    SELECT
        team_id,
        trace_id,
        parent_id,
        argMax(llm_input, started_at) as llm_input,
        argMax(llm_output, started_at) as llm_output
    FROM (
        SELECT
            team_id,
            trace_id,
            JSONExtractString(span_json, 'parent_id') as parent_id,
            JSONExtractString(span_json, 'attributes', 'input') as llm_input,
            JSONExtractString(span_json, 'attributes', 'output') as llm_output,
            JSONExtractFloat(span_json, 'started_at') as started_at
        FROM traces_data
        WHERE JSONExtractString(span_json, 'kind') = 'llm'
          AND JSONExtractString(span_json, 'parent_id') != ''
    )
    GROUP BY team_id, trace_id, parent_id
)
SELECT
    p.team_id AS team_id,
    p.span_id AS request_id,
    p.trace_id AS trace_id,
    p.span_id AS span_id,
    p.agent_name AS agent_id,
    coalesce(p.parent_agent_name, '') AS parent_agent_id,
    coalesce(p.parent_id, '') AS parent_span_id,
    CASE 
        WHEN p.status = 'ok' THEN 'success'
        WHEN p.status = 'error' THEN 'error'
        ELSE 'success'
    END AS status,
    CASE 
        WHEN p.ended_at > 0 AND p.started_at > 0 THEN (p.ended_at - p.started_at) * 1000
        ELSE 0
    END AS duration_ms,
    coalesce(l.llm_input, '') AS input_data,
    coalesce(l.llm_output, '') AS output_data,
    coalesce(p.agent_tools, '[]') AS agent_tools,
    coalesce(p.agent_output_type, '') AS agent_output_type,
    coalesce(p.framework, 'unknown') AS framework,
    '' AS error_message,
    p.ingested_at AS timestamp
FROM parent_agent_info p
LEFT JOIN llm_spans l ON p.span_id = l.parent_id 
    AND p.trace_id = l.trace_id 
    AND p.team_id = l.team_id
WHERE p.agent_name != '';

-- ============================================================================
-- API QUERY VIEWS (Optimized for common queries)
-- ============================================================================

-- View for agents list with metrics
-- Uses argMax to handle ReplacingMergeTree deduplication manually
CREATE VIEW IF NOT EXISTS neuraltrust.v_agents_with_metrics AS
WITH deduplicated_agents AS (
    SELECT
        team_id,
        agent_id,
        argMax(agent_name, updated_at) as agent_name,
        argMax(framework, updated_at) as framework,
        argMax(policy_role, updated_at) as policy_role,
        argMax(risk_level, updated_at) as risk_level,
        argMax(status, updated_at) as status,
        min(first_seen) as first_seen,
        max(last_activity) as last_activity
    FROM neuraltrust.agents
    GROUP BY team_id, agent_id
)
SELECT
    a.team_id as team_id,
    a.agent_id as agent_id,
    a.agent_name as agent_name,
    a.framework as framework,
    a.policy_role as policy_role,
    a.risk_level as risk_level,
    a.status as status,
    a.last_activity as last_activity,
    coalesce(g.guardian_count, 0) as guardian_invocations_24h,
    coalesce(r.request_count_24h, 0) as requests_24h,
    coalesce(r_total.request_count_total, 0) as requests_total,
    if(length(t.allowed_tools) > 0, t.allowed_tools, []) AS allowed_tools
FROM deduplicated_agents a
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        count() AS guardian_count
    FROM neuraltrust.guardian_invocations
    WHERE timestamp >= now() - INTERVAL 24 HOUR
    GROUP BY team_id, agent_id
) g ON a.team_id = g.team_id AND a.agent_id = g.agent_id
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        count() AS request_count_24h
    FROM neuraltrust.agent_requests
    WHERE timestamp >= now() - INTERVAL 24 HOUR
    GROUP BY team_id, agent_id
) r ON a.team_id = r.team_id AND a.agent_id = r.agent_id
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        count() AS request_count_total
    FROM neuraltrust.agent_requests
    GROUP BY team_id, agent_id
) r_total ON a.team_id = r_total.team_id AND a.agent_id = r_total.agent_id
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        groupArray(DISTINCT tool_name) AS allowed_tools
    FROM neuraltrust.agent_tool_permissions
    WHERE approved = true
    GROUP BY team_id, agent_id
) t ON a.team_id = t.team_id AND a.agent_id = t.agent_id;

-- View for agent permissions with request metrics
-- Uses argMax to handle ReplacingMergeTree deduplication manually
CREATE VIEW IF NOT EXISTS neuraltrust.v_agent_permissions_with_metrics AS
WITH deduplicated_permissions AS (
    SELECT
        team_id,
        agent_id,
        tool_id,
        argMax(tool_name, updated_at) as tool_name,
        argMax(tool_category, updated_at) as tool_category,
        argMax(tool_action, updated_at) as tool_action,
        argMax(approved, updated_at) as approved,
        min(first_requested) as first_requested,
        max(last_requested) as last_requested
    FROM neuraltrust.agent_tool_permissions
    GROUP BY team_id, agent_id, tool_id
),
permissions_with_metrics AS (
    SELECT
        p.team_id as team_id,
        p.agent_id as agent_id,
        p.tool_id as tool_id,
        p.tool_name as tool_name,
        p.tool_category as tool_category,
        p.tool_action as tool_action,
        p.approved as approved,
        p.last_requested as last_requested,
        coalesce(r24.request_count, 0) as requests_24h,
        coalesce(r1m.request_count, 0) as requests_1m
    FROM deduplicated_permissions p
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        tool_id,
        count() AS request_count
    FROM neuraltrust.tool_requests
    WHERE timestamp >= now() - INTERVAL 24 HOUR
    GROUP BY team_id, agent_id, tool_id
) r24 ON p.team_id = r24.team_id AND p.agent_id = r24.agent_id AND p.tool_id = r24.tool_id
LEFT JOIN (
    SELECT 
        team_id,
        agent_id,
        tool_id,
        count() AS request_count
    FROM neuraltrust.tool_requests
    WHERE timestamp >= now() - INTERVAL 30 DAY
    GROUP BY team_id, agent_id, tool_id
    ) r1m ON p.team_id = r1m.team_id AND p.agent_id = r1m.agent_id AND p.tool_id = r1m.tool_id
)
SELECT
    team_id,
    agent_id,
    tool_id,
    tool_name,
    tool_category,
    tool_action,
    approved,
    last_requested,
    requests_24h,
    requests_1m
FROM permissions_with_metrics;

-- View for agent dependency graph
-- Uses argMax to handle ReplacingMergeTree deduplication manually
CREATE VIEW IF NOT EXISTS neuraltrust.v_agent_dependency_graph AS
WITH deduplicated_deps AS (
    SELECT
        team_id,
        source_agent_id,
        target_type,
        target_id,
        argMax(target_name, updated_at) as target_name,
        argMax(dependency_type, updated_at) as dependency_type,
        sum(connection_count) as connection_count,
        min(first_seen) as first_seen,
        max(last_seen) as last_seen
    FROM neuraltrust.agent_dependencies
    GROUP BY team_id, source_agent_id, target_type, target_id
)
SELECT
    team_id as team_id,
    source_agent_id as source_agent_id,
    target_type as target_type,
    target_id as target_id,
    target_name as target_name,
    dependency_type as dependency_type,
    connection_count as connection_count,
    last_seen as last_seen
FROM deduplicated_deps
WHERE last_seen >= now() - INTERVAL 7 DAY
ORDER BY connection_count DESC;
