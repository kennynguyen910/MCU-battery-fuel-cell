# Historical voltage view

## Use it

1. Select a saved test session in the web application.
2. Leave From/To blank to see the full session, or enter UTC timestamps such as
   2026-09-14T01:40:30Z. Optional fractional seconds through microseconds are accepted,
   such as 2026-09-14T01:40:30.000500Z.
3. Press Apply time range. The API filters measurements, including both endpoints.
4. Choose Graph CH 1 through Graph CH 16.
5. Clear time range restores the full session.

The latest-value list below the graph uses the same range. It may therefore show
an older value when an end time is selected. An empty range shows no points and
no latest values; it does not retain values from the previous query.

## Interpretation

Every dot is a saved sample for that channel. Horizontal spacing represents the
actual elapsed time between timestamps. Lines connect samples for readability;
they do not add measurements in the gaps. The first and last timestamps are
printed below the graph. The vertical axis is labeled in volts and adjusts to
the selected data, so compare axis labels before comparing graph shapes.

One sample is a dot at the center of the plot. A constant-voltage series gets a
small vertical margin, avoiding a zero-height axis. No graphing package or
simulation engine is involved: Flutter CustomPainter draws the data.

## Implementation

history.dart validates UI boundaries and draws points. screens.dart encodes the
selected range as query parameters. A response is accepted only if both its
session and filter still match the current selection, preventing a slower old
request from replacing newer results. Express validates date ranges before
passing them to the store. Postgres uses parameterized timestamp comparisons.

The current design loads every measurement in the selected range each second.
This is suitable for manual tests. Pagination/aggregation is still needed for
high-rate and long-duration hardware sessions.
