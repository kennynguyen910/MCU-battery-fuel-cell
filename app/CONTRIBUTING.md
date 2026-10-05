# Contributing

This repository is a student capstone, so clarity and evidence matter more than
cleverness. Keep changes small enough that another team member can explain them.

## Before changing code

1. Read `docs/requirements.md` and identify the requirement affected.
2. Read `docs/architecture.md` before moving responsibility between components.
3. Do not make visual-design decisions until the team has approved them.
4. Never commit `.env`, `.tools`, `.local`, signing keys, database files, or logs.

## Authored versus generated code

Add student-friendly comments to authored logic. Comments should explain why a
boundary, validation rule, retry, or unusual operation exists; they should not
merely repeat the syntax. Flutter-generated Android/iOS host files, Gradle's
wrapper, image assets, dependency lockfiles, and compiled output are generated
artifacts and should not be manually filled with redundant comments.

## Required checks

Run `executables\90_Run_All_Tests.cmd`. If Dart source changed, also rebuild web.
If native configuration or shared collector code changed, rebuild Android.
Record any deliberately unverified platform in `docs/verification.md`.

## Commit guidance

- Use a short imperative summary, such as `Validate measurement timestamps`.
- Keep unrelated changes in separate commits.
- Do not describe a feature as complete unless its acceptance evidence passes.
- Update the API/architecture documentation in the same commit as contract changes.
