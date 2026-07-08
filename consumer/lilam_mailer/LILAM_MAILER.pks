create or replace PACKAGE LILAM_MAILER AS

    ----------------------------------------------------------------
    -- Sample Consumer 
    -- Listens for DBMS_ALERT.SIGNAL triggers from LILAM.
    -- Based on LILAM_CONSUMER this package implements only mail centric features
    ----------------------------------------------------------------

    -- Alerting Channel
    -- To be used as handler in ruleset
    C_ALERT_MAIL_LOG CONSTANT VARCHAR2(30) := 'LILAM_ALERT_MAIL_LOG';
    
    -- Starts consumer
    -- Regulary you would start this in background with DBMS_SCHEDULER
    procedure runMailer;

END LILAM_MAILER;
