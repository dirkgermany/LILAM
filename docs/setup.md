# Setting up LILAM

## Overview
Since LILAM is a PL/SQL package, only a few steps are required for commissioning and use.

Ultimately, three database objects are required:
* Three Tables
* One Sequence

All objects are created when the API is used for the first time.
Even if the names of the log tables deviate from the standard (the names can be optionally specified when using the API), they are created automatically.
This does not apply to the name of the Sequence, which is mandatory.

Also the schema user must have the necessary rights.
As a rule, these rights should already be in place, as LILAM is only a supplement to existing PL/SQL packages.

---
## Prerequisites
If you are new to PL/SQL programming or are using a new database user to try out LILAM, there may be a few Oracle-specific preparations to make.

### Privileges of your schema user
Grant the user certain rights (also with sysdba rights)
```sql
-- Core Privileges (In-Session Mode)
GRANT CREATE SESSION TO USER_NAME;
GRANT CREATE TABLE TO USER_NAME;
GRANT CREATE SEQUENCE TO USER_NAME;
GRANT EXECUTE ON LILAM TO USER_NAME;

-- Server-based Privileges (Decoupled Mode)
GRANT EXECUTE ON DBMS_PIPE TO USER_NAME;
GRANT SELECT ON V_$DB_PIPES TO USER_NAME; -- Required for precision server routing

-- Later versions
GRANT CREATE JOB TO USER_NAME;            -- Required to run LILAM-Servers as background job
GRANT EXECUTE ON UTL_HTTP TO USER_NAME;   -- To allow LILAM send metrics via external web services

```

### Creating Package
Find the package under https://github.com/dirkgermany/LILAM/tree/main/source/package.

Copy the complete content of lilam.pks (specification) and lilam.pkb (body) into your preferred sql tool (e.g. sqlDeveloper) and execute the sql script.
After that you can see the package in your object tree (perhaps after refreshing it).

That's it. If you got exceptions when executing the scripts please see [`Trouble Shooting`](#trouble-shooting).

---
## Trouble shooting
Hopefully not, but errors may occur when using LILAM for the first time.

### Database Objects
If, for any reason, one or all of the three required database objects are not automatically created when using the API, they can be created manually using the following statements if necessary.

>If you want to use names for the log tables that do not correspond to the default, this must be taken into account in the corresponding statements (see below)! 

#### Create Sequence
```sql
-- With executing the follogin statement the Sequence will be created
CREATE SEQUENCE SEQ_LILAM_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL
```

#### Create Tables
```sql
-- Create MASTER Table
-- Customise the name of the MASTER table here if it differs from the default
create table LILAM_LOG (
    id number(19,0),
    process_name varchar2(100),
    process_start timestamp(6),
    process_end timestamp(6),
    last_update timestamp(6),
    steps_todo NUMBER,
    steps_done number,
    status number(1,0),
    info clob
);

-- Create DETAIL Table
-- Customise the name of the DETAIL table here if it differs from the default
create table LILAM_LOG_DETAIL (
    process_id number(19,0),
    no number(19,0),
    info clob,
    log_level varchar2(10),
    session_time timestamp  DEFAULT SYSTIMESTAMP,
    session_user varchar2(50),
    host_name varchar2(50),
    err_stack clob,
    err_backtrace clob,
    err_callstack clob
);
```


## Testing
After all creation steps are done successfully, you can test LILAM by calling the life check :)
```sql
-- call LILAM
execute lilam.is_alive;
-- show LILAM log data
select * from LILAM_LOG;
select * from LILAM_LOG_DETAIL;
```
