# simpleOraLogger API

## Overview
simpleOraLogger is nothing more than a PL/SQL Package.
To shorten the procedures and functions the package is named SO_LOG (package and body).

This package enables logging from other packages.
Different packages can use logging simultaneously from a single session and write to either dedicated or the same LOG table.
        
Even when using a shared LOG table, the LOG entries can be identified by process name and — in the case of multiple calls to the same process — by process IDs (filtered via SQL).
For reasons of clarity, however, the use of dedicated LOG tables is recommended.
        
The LOG entries are persisted within encapsulated transactions. This means that logging is independent of the (missing) COMMIT of the calling processes.

## LOG Tables
Logging takes place in two tables. Here I distinguish them by '1' and '2'.

Table '1' is the leading table and contains the started processes, their names, and status. There is exactly one entry in this table for each process and log session.

The entries in Table 2 contain further details corresponding to the entries in Table 1.

Both tables have standard names.
At the same time, the name of table '1' is the so-called prefix for table '2'.
        
* The default name for table '1' is LOG_PROCESS.
* The default name for table '2' is LOG_PROCESS_DETAIL
       
The name of table '1' can be customized; for table '2', the 
selected name of table '1' is added as a prefix and _DETAIL is appended.
    
Example:
Selected name '1' = MY_LOG_TABLE

Set name '2' is automatically = MY_LOG_TABLE_DETAIL

## Sequence
Logging uses a sequence to assign process IDs. The name of the sequence is SEQ_LOG.

## Log Level
Depending on the selected log level, additional information is written to table ‘2’ (_DETAIL).
        
To do this, the selected log level must be >= the level implied in the logging call.

>logLevelSilent -> No details are written to table '2'
>
>logLevelError  -> Calls to the ERROR() procedure are taken into account
>
>logLevelWarn   -> Calls to the WARN() and ERROR() procedures are taken into account
>
>logLevelInfo   -> Calls to the INFO(), WARN(), and ERROR() procedures are taken into account
>
>logLevelDebug  -> Calls to the DEBUG(), INFO(), WARN(), and ERROR() procedures are taken into account
