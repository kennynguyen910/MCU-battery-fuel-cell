# GitHub and second-computer transfer

## What GitHub contains

GitHub stores source code, tests, documentation, lockfiles, schemas, and the
small numbered launchers. It intentionally excludes about 16 GB of SDKs/caches,
the local PostgreSQL data directory, `.env`, APK/build output, and capture logs.

This keeps the repository reviewable and prevents one computer's absolute paths
or private data from breaking another computer.

## Move to another Windows computer

1. Install Git for Windows if it is not already installed.
2. Clone the private repository, or use GitHub's **Code → Download ZIP** and
   extract it to a short path such as `C:\Capstone`.
3. Open the `executables` folder.
4. Run `00_First_Time_Setup.cmd`. Internet access is required. It installs Node
   when necessary and recreates pinned Flutter, portable PostgreSQL, dependencies,
   the database/schema, and the Flutter web build.
5. Run `10_Start_Web_System.cmd` for the normal demo.
6. For native Android, run `00B_First_Time_Android_Setup.cmd`. This is a separate
   multi-gigabyte download and pauses for the official Android licenses.
7. Start Android with launcher 05, wait for its home screen, then run launcher 06.

The browser collector is available even without the optional Android download,
so the full logical data path can still be demonstrated on a smaller computer.

## Normal Git workflow

```powershell
git pull
git status
git add <specific files>
git commit -m "Describe one logical change"
git push
```

Review `git status` before every commit. If `.env`, `.local`, `.tools`, an APK,
or a signing key appears, stop and correct `.gitignore` before committing.

## Data does not transfer through Git

Existing local sessions and measurements remain in `.local\pgdata` and are not
uploaded. This is intentional. Transfer approved data separately using a defined
export/backup process; never publish database files simply to make a demo match.
