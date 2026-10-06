CAPSTONE WINDOWS LAUNCHERS
==========================

On a newly cloned computer:
  1. Double-click 00_First_Time_Setup.cmd once.
  2. Double-click 10_Start_Web_System.cmd for the normal demonstration.

Optional Android setup (large download):
  1. Double-click 00B_First_Time_Android_Setup.cmd once.
  2. Read and answer the official Android license prompts yourself.

To understand or troubleshoot each component, start these in order:
  01_Start_Database.cmd
  02_Start_API.cmd                 (keep its window open)
  03_Start_Web_Previews.cmd        (keep its window open)
  04_Open_Dashboards.cmd

Android is optional:
  05_Start_Android_Emulator.cmd
  06_Install_And_Open_Android_App.cmd

Development checks:
  90_Run_All_Tests.cmd
  91_Build_Web.cmd
  92_Build_Android.cmd

The database can be stopped with 99_Stop_Database.cmd. Closing only the API or
preview windows does not delete data. Do not delete .local\pgdata: it contains
the local PostgreSQL database.
AWS DATABASE (AFTER AN RDS DATABASE HAS BEEN CREATED)
-----------------------------------------------------
00C_Configure_AWS_Database.cmd
  Run once on each computer that should use the AWS development database.
  It checks port 5432, asks for the password privately, installs the schema,
  and stores the local connection in the Git-ignored .env file.
