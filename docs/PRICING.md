# Dynamic pricing

Costs in Token Bar are always **estimates, never a bill**. Subscription or
flat-rate use (Copilot, Luna, Muse Spark contributor) is not an API invoice.
The dynamic catalog only refreshes the per-1M estimate rates; the cost
formula is unchanged (`(input-cached)*input + cached*cached + output*output`,
per 1M, USD; cached is a subset of input, reasoning rides inside output).

## Source rationale

Primary dynamic source: **OpenRouter Models API**, `GET
https://openrouter.ai/api/v1/models` (documented at
`https://openrouter.ai/docs/api-reference/overview` and
`https://openrouter.ai/docs/guides/overview/models`).

Why this endpoint:

- Public structured JSON over a single GET, no auth, no key, no query.
- One response covers every observed metered family (OpenAI GPT, Anthropic
  Claude, Google Gemini) with `pricing.prompt` / `pricing.completion` USD
  per-token decimal strings (x1M for our per-1M table) plus optional
  `input_cache_read` / `input_cache_write` cache rates.
- Single-provider price pages (OpenAI, Anthropic, Google) are HTML, not
  structured GET endpoints, and none covers all three families -- so no
  single official provider catalog can cover the observed models. The
  pluggable normalized cache format below is the answer to that gap.

Coverage limits (documented, by design):

- Internal / subscription-only ids have no public listing and are NOT in any
  catalog: `github-copilot/gpt-5.6-sol`, `openai/gpt-5.6-luna`,
  `opencode-go/muse-spark-1.3-contributor`. They keep the static exact
  approximations in `Pricing.swift` (nearest family rate, clearly labeled).
- A catalog entry without `input_cache_read`/`input_cache_write` bills
  cached tokens at the input rate (no invented discount).
- Bare usage models (`gpt-4o`) match provider-prefixed catalog ids
  (`openai/gpt-4o`) via deterministic suffix match (lexically smallest id
  wins); prefixed keys that match nothing fall through to the static family
  table instead of guessing across providers.

## Pluggable catalog format

`PricingCatalog` (version 1) is the contract: any future provider decoder
normalizes into `{version, sourceURL, fetchedAt, entries[]}` with per-1M
`inputPerMTok / outputPerMTok / cachedPerMTok`, then persists through
`PricingCatalogCodec`. Resolution and the app/CLI never parse provider JSON
directly, so adding a source (for example the LiteLLM
`model_prices_and_context_window.json` raw file or the
`https://models.litellm.ai/model_catalog` GET API) means one new decoder
function, no resolver changes.

## Resolution precedence (deterministic, case-insensitive)

1. Dynamic catalog entry (fresh snapshot, fetched live this session).
2. Cached catalog entry (on-disk snapshot, stale or offline).
3. Static exact `provider/model` table in `Pricing.swift`.
4. Static family/substring table, in order.
5. Fallback rate (`$3.00 / $12.00 / $1.50`), never zero.

Unknown models stay visible: they keep their raw label in `byModel` and
price at fallback. `Pricing.resolve` returns the `PriceOrigin`
(`dynamicCatalog | cachedCatalog | staticEstimate | fallback`) alongside
every rate; the UI/CLI surface it as `Pricing: <origin> (<host>,
<N> models, updated <age>)`.

## Refresh bounds and cache

- The ONLY network call in the codebase is `PricingService.refresh()`:
  one `GET` against the catalog URL, 15s request timeout (30s resource),
  5MB response cap, 10k-model decode cap. Cancellable via `Task` cancel.
- Refresh is strictly user-initiated or explicitly flagged: the app
  **Update pricing** button, or CLI `--refresh-pricing`. Startup, usage
  loading, tests, and default CLI runs never touch the network.
- Cache: `~/Library/Application Support/TokenBar/pricing-catalog.json`
  (override `TOKENBAR_PRICING_CACHE` for tests). Entries carry `fetchedAt`;
  older than 7 days counts as cached/stale. Missing or malformed caches are
  ignored with an offline message -- usage loading never breaks.
- CLI stays deterministic and offline by default (static table, historic
  output byte-for-byte). `--refresh-pricing` runs one bounded refresh
  (`URLSession` 15s request / 30s resource timeouts), then prices from the
  fresh snapshot, the cache on failure, or static estimates with an error note.

## Privacy

The pricing request carries no body, no query items, and no
`Authorization`/`Cookie` headers -- just `Accept: application/json`.
Prompts, token counts, file paths, credentials, cookies, and usage records
are never sent; only public model/pricing metadata is requested. Pinned by
`PricingCatalogTests.testCatalogRequestSendsNoUsageOrCredentials` plus the
CI privacy job (URLSession confined to `PricingService.swift`, catalog
hosts allowlisted to `openrouter.ai`).
