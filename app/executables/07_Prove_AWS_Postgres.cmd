@echo off
setlocal
call "%~dp0_environment.cmd"
REM psql itself reads the password privately; never put it in this file.
set "PGSSLMODE=verify-full"
set "PGSSLROOTCERT=%CAPSTONE_ROOT%\.local\aws\global-bundle.pem"
set "PGCONNECT_TIMEOUT=15"
echo Target: capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com:5432
echo Database: capstone  User: capstone_admin  SSL: verify-full
echo psql --host=capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com --port=5432 --dbname=capstone --username=capstone_admin -W -a -f database\connection-proof.sql
"%CAPSTONE_ROOT%\.tools\pgsql\bin\psql.exe" --host=capstone-postgres.cj0kowcoegeo.us-east-2.rds.amazonaws.com --port=5432 --dbname=capstone --username=capstone_admin -W -a --set=ON_ERROR_STOP=1 -f "%CAPSTONE_ROOT%\database\connection-proof.sql"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo Database proof failed. Check the RDS My IP rule, password, and certificate.
pause
exit /b %RESULT%
