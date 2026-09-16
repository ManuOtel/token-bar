# Brand assets (third-party provider marks)

Token Bar's own mark is `site/assets/tokenbar-logo.svg` (the orbit logo,
primary everywhere). The three source marks below are **real provider
artwork**, bundled locally so the README and the static site never fetch
images at runtime. Each file is used exactly as shipped by its owner,
except for the one dark-theme fill adaptation noted in the table.

No file here is a Token Bar invention. All provider marks remain the
property of their respective owners and are shown only to identify the
local usage source they correspond to. This is not an endorsement by, or
affiliation with, any provider.

| Provider | Bundled file | Official source | Retrieved | License / trademark note |
|---|---|---|---|---|
| OpenCode (Anomaly) | `site/assets/provider-opencode-light.svg` (SHA-256 `00ac8ac1…cd321`) | `https://github.com/sst/opencode` (`packages/web/src/assets/logo-light.svg`, `dev` branch; same artwork as `https://opencode.ai/brand`) | 2026-09-16 | Artwork by the OpenCode authors; repository is MIT-licensed. "OpenCode" wordmark is a trademark of its owner. Light-background variant, byte-identical to upstream. |
| OpenCode (Anomaly) | `site/assets/provider-opencode-dark.svg` (SHA-256 `231e3f47…47170ee`) | `https://github.com/sst/opencode` (`packages/web/src/assets/logo-dark.svg`, `dev` branch; same artwork as `https://opencode.ai/brand`) | 2026-09-16 | Same as above. Dark-background variant, byte-identical to upstream. |
| Claude Code (Anthropic) | `site/assets/provider-claude-spark.svg` (SHA-256 `6d53db4b…48bef25`) | `https://anthropic.com/press-kit` (official Anthropic press kit, "Claude logos / 3 Claude Spark / SVG / Claude Spark - Clay.svg") | 2026-09-16 | Artwork by Anthropic PBC. The single clay (`#D97757`) color reads on light and dark backgrounds, so one file serves both themes. Byte-identical to the press-kit file. "Claude" is a trademark of Anthropic. The compact Spark was chosen over the full Claude Code lockup for legibility at 18-26 px; the full Slate/Ivory lockups ship in the same press kit. |
| OpenAI (for OpenAI Codex) | `site/assets/provider-openai-blossom.svg` (SHA-256 `ca35a572…ef873cc7`) | `https://openai.com/brand/` via Wikimedia Commons `File:OpenAI logo 2025 (symbol).svg` (page documents Source: `https://openai.com/brand/`, Author: OpenAI) | 2026-09-16 | Artwork by OpenAI. `openai.com` serves bot-protection pages to scripts, so the bytes were retrieved through the Commons mirror that cites the official brand page as its source; geometry verified as the current Blossom knot. Byte-identical to the mirror. "OpenAI" is a trademark of OpenAI. |
| OpenAI (for OpenAI Codex, dark theme) | `site/assets/provider-openai-blossom-inverse.svg` (SHA-256 `31c1e09b…16c9e5a6`) | Derived locally from the file above | 2026-09-16 | Same ownership as above. Geometry is identical to the official file; the only change is a single root `fill="#fff"` presentation attribute so the black mark stays legible on the site's dark theme (the same reason OpenCode itself ships official light/dark fill pairs). No endorsement claim. |

## Codex branding limitation

There is **no standalone Codex mark**. The official `openai/codex`
repository ships no logo asset (its `.github/` directory holds only a CLI
splash screenshot, not a mark), and OpenAI's brand page offers the OpenAI
Blossom/wordmark only. Token Bar therefore shows the official OpenAI
Blossom and labels the source precisely as **"OpenAI Codex"** everywhere a
provider logo appears, instead of claiming a Codex-specific logo exists.
Source identifiers in code, CLI flags, and config (`codex`) are unchanged.

## Rules for touching these files

- Never redraw, recolor (beyond the documented inverse variant), or
  re-export provider artwork. To update, re-download from the official
  source above, replace the file, and refresh the SHA-256 in this table.
- Keep every reference document-relative (`assets/...` on the site,
  `site/assets/...` in the README) so the page works under both the
  GitHub Pages project subpath and the custom domain.
- Never hotlink provider images at runtime; the site's contract
  (`scripts/test-site.sh`) rejects remote `<img>` embeds.
