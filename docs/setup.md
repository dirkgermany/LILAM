# Setting up LILA

## Overview
Since LILA is a pl/sql package, only a few steps are required for commissioning and use.

Ultimately, three database objects are required:
* Two Tables
* One Sequence

All objects are created when the API is used for the first time.
Even if the names of the log tables deviate from the standard (the names can be optionally specified when using the API), they are created automatically.
This does not apply to the name of the Sequence, which is mandatory.

Also the schema user must have the necessary rights.
As a rule, these rights should already be in place, as LILA is only a supplement to existing PL/SQL packages.

## Login to database schema
Within your preferred sql tool (e.g. sqlDeveloper) login to the desired database schema.

## Creating Package
Is done by copy&paste and execute
1. Copy the complete content of lila.pks (the specification) into your preferred sql tool (e.g. sqlDeveloper) and execute the sql script
2. Copy the complete content of lila.pkb (the body) and execute the sql script
3. Open the new package LILA (perhaps you have to refresh the object tree in your sql tool)

That's it. If you got exceptions when executing the scripts please see [`Trouble Shooting`](#trouble-shooting).


## Trouble shooting
### Permissions
Most problems are caused by insufficient permissions.
Log in to the database with DBA rights(*sys* or *system*).
Execute the following statements. You may want to try this iteratively, executing one statement at a time and attempting to perform the setup steps immediately after each one.
```sql
GRANT CREATE SESSION TO <schema user>;
GRANT CREATE TABLE TO <schema user>;
GRANT CREATE PROCEDURE TO <schema user>;
GRANT CREATE SEQUENCE TO <schema user>;
```

If the user who executes your scripts, is not the same, you have to grant one more Privilege:
```sql
GRANT EXECUTE ON <schema user>.LILA TO <another schema user>;
```
### Database Objects
If, for any reason, one or all of the three required database objects are not automatically created when using the API, they can be created manually using the following statements if necessary.

>If you want to use names for the log tables that do not correspond to the default, this must be taken into account in the corresponding statements (see below)! 

#### Create Sequence
```sql
-- With executing the follogin statement the Sequence will be created
CREATE SEQUENCE SEQ_LILA_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL
```

#### Create Tables
```sql
-- Create MASTER Table
-- Customise the name of the MASTER table here if it differs from the default
create table LILA_LOG (
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
create table LILA_LOG_DETAIL (
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
After all creation steps are done successfully, you can test LILA by calling the life check :)
```sql
-- call LILA
execute lila.is_alive;
-- show LILA log data
select * from LILA_LOG;
select * from LILA_LOG_DETAIL;
```
