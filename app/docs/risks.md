# MVP risk register

This register separates demonstrated behavior from work that still carries
technical or project risk. Likelihood and impact are qualitative MVP estimates.

| Risk | Likelihood | Impact | Current mitigation | Next decision/work |
| --- | --- | --- | --- | --- |
| Hardware protocol differs from the manual frame contract | Medium | High | Device input boundary is isolated behind one endpoint | Team must agree on BLE/CAN/Wi-Fi framing, clock, units, and error behavior |
| Fast frames replace one another before the one-second poll | High at real sample rates | High | Clearly limited to manual tests; local collector never invents intermediate data | Add a sequenced queue/batch protocol before hardware integration |
| Mobile app closes or is suspended during capture | Medium | High | Captured frames are logged before upload; pending frames retry | Define background acquisition requirements per platform |
| Device and server clocks disagree | Medium | Medium | All API times normalize to UTC; manual endpoint supplies current server time | Define authoritative clock and synchronization strategy for firmware |
| Two collectors capture the same session | Low in demo | Medium | Runbook specifies one collector | Add session ownership/lease if multi-operator use is required |
| Long sessions overload full-history polling | High at production rates | High | MVP is explicitly for short manual sessions | Add pagination/downsampling, bulk insert, and independent UI refresh rate |
| Local log grows indefinitely | Low in manual demo | Medium | Log is inspectable and small for current use | Add rotation/export/retention before continuous acquisition |
| Public deployment exposes unauthenticated data/actions | Certain if deployed unchanged | High | Service remains loopback/local; deployment gate forbids public exposure | Add auth, restrictive CORS, HTTPS, secrets, and least-privilege roles |
| Database loss | Low locally | High | Project database is persistent across app restarts | Establish cloud backups and prove restore before real data collection |
| iOS-specific behavior remains untested on Windows | Certain | Medium | Shared Dart logic is tested; iOS host source exists | Run Xcode build, simulator/device networking, file storage, and signing tests on a Mac |
| Aesthetic decisions cause late functional rewrites | Medium | Medium | UI roles and data logic are separated; aesthetics intentionally deferred | Team agrees on wireframes before restyling; preserve tested behavior |

Review this table when hardware, cloud deployment, sim-mode, or visual design
enters scope. A risk is not “resolved” merely because it did not occur in a short demo.
