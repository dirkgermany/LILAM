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
GRANT EXECUTE ON DBMS_ALERT TO USER_NAME;   -- To allow LILAM send alerts
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
## Testing
After all creation steps are done successfully, you can test LILAM by calling the life check :)
```sql
-- call LILAM
execute lilam.is_alive;
-- show LILAM log data
select * from LILAM_LOG;
select * from LILAM_LOG_DETAIL;
```
