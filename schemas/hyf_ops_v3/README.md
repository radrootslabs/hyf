# Operation contract v3

`context.versions.schema = "hyf_ops_v3"` selects the current contract for
`farm_update.interpret`, `buyer_request.interpret` and `buyer_request.match`.
The envelope remains version 1. These operations are **not activated**: the
daemon validates the versioned context and returns `capability_unavailable`
before legacy dispatch or provider execution. Full input/response schema and
semantic enforcement must be completed before activation. Schema examples and
reference checks do not establish that runtime enforcement.

V2 remains only as historical pre-activation parser/rejection characterization.
Its farm context, scaled money and model identifiers do not define v3. The
unversioned operation journeys must be characterized and cut over explicitly
before activation; they cannot become a second active business engine.

Public shared SDK wire values are mirrored exactly:

- Quantity is `{amount, unit}`. Amount is a canonical nonnegative decimal
  string with coefficient at most 999999999999 and scale at most 6. Units are
  `g`, `kg`, `mL`, `L` and integral `each`. Unknown quantity is an explicit
  alternative; it is never encoded as zero. Approximation remains explicit.
- Money is `{currency, minor, exponent}`. Minor amount is a canonical integer
  string at most 999999999999999; currency and exponent must match the pinned
  public registry. Registry data includes its Apache license and attribution.
  No conversion, price basis, fee, tax or exchange rate is inferred.
- Evaluation, source and ingestion timestamps use the shared `UnixSeconds`
  representation: unsigned canonical ASCII strings from 0 to 253402300799.
  RFC3339 is not an alternative v3 encoding. Relative language, source recency
  and timezone interpretation remain shared SDK/host responsibilities.

Actor and workspace fields are descriptors. Parsing them does not authenticate
a participant or create an SDK `CommandContext`. The native host retains its
authenticated context and revalidates current scope, revisions and business
preconditions before any later use. A farm/organization association is optional;
buyer requests never need a private stock pool identifier.

Matching consumes authorized SDK projections and returns bounded suggestions
with explicit uncertainty, coverage and `commitment: "none"`. It owns no stock
allocation, reservation, order, permission or signing action. A source message
or model score cannot override an SDK failure. Consulted-record provenance must
be based on actual use, independently of whether a suggestion was produced.
Source evidence uses UTF-8 byte offsets and exact revisions.

The model axis is exact `jev-1.14.0`. Account/model availability and actual
returned identity require separate live qualification. Zero provider calls
requires null execution model and question bundle; manifest strings alone do
not prove model use. Existing frame, depth, provider, deadline, attempt and
cleanup limits remain binding as recorded in `manifest.json`.
