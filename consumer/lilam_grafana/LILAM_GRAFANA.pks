create or replace PACKAGE LILAM_GRAFANA AS

    ----------------------------------------------------------------
    -- Sample consumer: forwards LILAM alerts to Grafana as annotations.
    -- Listens for DBMS_ALERT signals of one channel (alert.handler of the rules)
    -- and processes the PENDING alerts of one group from LILAM_ALERTS.
    --
    -- Grafana target: POST <url>/api/annotations (HTTP API, Bearer token).
    -- Without URL nothing leaves the database: the request is only written to
    -- LILAM_GRAFANA_OUTBOX (send_status SIMULATED) - an imaginary Grafana service.
    --
    -- Note: LILAM_ALERTS has one STATUS per alert. Only one consumer may process
    -- a channel/group combination (e.g. not LILAM_MAILER at the same time for the same alerts).
    ----------------------------------------------------------------

    -- Default channel and group of the subway example (docs/architecture and concepts.md)
    C_DEFAULT_CHANNEL CONSTANT VARCHAR2(30) := 'LILAM_ALERT_MAIL_LOG';
    C_DEFAULT_GROUP   CONSTANT VARCHAR2(50) := 'SUBWAY';
    -- Signal that ends RUN (see STOP)
    C_STOP_CHANNEL    CONSTANT VARCHAR2(30) := 'LILAM_GRAFANA_STOP';

    -- Main loop: processes pending alerts at start, after every signal and at least every p_waitSeconds.
    -- Ends after STOP or after p_maxSeconds (NULL = endless). Usually started as a scheduler job (START_JOB).
    -- p_token is kept in memory only.
    PROCEDURE RUN(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_token        VARCHAR2 DEFAULT NULL,
        p_dashboardUid VARCHAR2 DEFAULT NULL,
        p_maxSeconds   NUMBER   DEFAULT NULL,
        p_waitSeconds  NUMBER   DEFAULT 60);

    -- Processes all PENDING alerts of the channel and group once; returns the number of processed alerts
    -- (sent or simulated). Alerts that cannot be sent get STATUS = ERROR.
    FUNCTION PROCESS_PENDING(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_token        VARCHAR2 DEFAULT NULL,
        p_dashboardUid VARCHAR2 DEFAULT NULL) RETURN PLS_INTEGER;

    -- Grafana annotation (JSON) for one alert, e.g. for tests or a different transport
    FUNCTION BUILD_ANNOTATION(p_alertId NUMBER, p_dashboardUid VARCHAR2 DEFAULT NULL) RETURN CLOB;

    -- Starts RUN as scheduler job LILAM_GRAFANA_<group>. No token parameter on purpose: the job action
    -- is visible in USER_SCHEDULER_JOBS. Without URL: simulated Grafana (outbox only).
    PROCEDURE START_JOB(
        p_channel      VARCHAR2 DEFAULT C_DEFAULT_CHANNEL,
        p_groupName    VARCHAR2 DEFAULT C_DEFAULT_GROUP,
        p_url          VARCHAR2 DEFAULT NULL,
        p_maxSeconds   NUMBER   DEFAULT NULL);

    -- Ends all running RUN loops (signal C_STOP_CHANNEL)
    PROCEDURE STOP;

END LILAM_GRAFANA;
/
