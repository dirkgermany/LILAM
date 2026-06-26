# Setting up LILAM

## Overview

Since LILAM is a pure PL/SQL package, deploying and using it requires only a few simple steps.

The framework relies on the following database objects:
* Three tables
* One sequence

All objects are created automatically upon the first API call. Even if you choose custom names for the log tables (which can optionally be passed to the API), LILAM handles their creation on the fly. Please note that the sequence name is mandatory and must be provided.

Additionally, the schema user must have the necessary privileges. In most enterprise environments, these rights are already granted, as LILAM is designed to complement your existing PL/SQL applications.

## Prerequisites

If you are new to PL/SQL development or are using a fresh database user to test LILAM, you might need to perform a few Oracle-specific preparations first.

### Privileges of your schema user

Execute the following grants to provide the user with the required privileges (requires `SYSDBA` or administrative rights):

```sql
-- Core Privileges (In-Session Mode)
GRANT CREATE SESSION TO USER_NAME;
GRANT CREATE TABLE TO USER_NAME;
GRANT CREATE SEQUENCE TO USER_NAME;
GRANT EXECUTE ON LILAM TO USER_NAME;

-- Server-based Privileges (Decoupled Mode)
GRANT EXECUTE ON DBMS_ALERT TO USER_NAME;   -- Allows LILAM to send alerts
GRANT EXECUTE ON DBMS_PIPE TO USER_NAME;
GRANT SELECT ON V_\$DB_PIPES TO USER_NAME;   -- Required for precision server routing

-- Job and Network Privileges (Background & Modern Features)
GRANT CREATE JOB TO USER_NAME;              -- Required to run LILAM servers as background jobs
GRANT EXECUTE ON UTL_HTTP TO USER_NAME;     -- Allows LILAM to stream metrics via external web services
```

## Installing the Package

The package code is located within the `source` folder of each release. Alternatively, you can access it directly via [GitHub LILAM Source Package](https://github.com).

1. Copy the complete content of `lilam.pks` (Package Specification) and `lilam.pkb` (Package Body).
2. Paste it into your preferred SQL tool (e.g., Oracle SQL Developer, PL/SQL Developer, or VS Code).
3. Execute the scripts. 

Once compiled, the package will appear in your database object tree (you may need to refresh the view).

*Note: If you encounter any compilation errors or exceptions while executing the scripts, please refer to the Troubleshooting section.*

## Testing the Installation

After completing the setup steps, you can verify that LILAM is working correctly by running a quick health check:

```sql
-- Call the LILAM life check
EXECUTE lilam.is_alive;

-- Query the LILAM log data to verify automatic table creation
SELECT * FROM lilam_log;
SELECT * FROM lilam_log_detail;
```




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
The package code is located within the `source` folder of each release. Alternatively, you can access it directly via https://github.com/dirkgermany/LILAM/tree/main/source/package.

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
