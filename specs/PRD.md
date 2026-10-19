# PRD: cvwriter

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19. From docs/claude-pkg/TEMPLATE-PRD.md. -->

## The problem
A job seeker who applies to many roles rewrites their CV for every ad and still
leads with the wrong thing. Keywords get a CV past the applicant-tracking system
(ATS). What gets the interview is showing the recruiter you can fix the problem
the ad is quietly describing ("build HR from scratch" means there is no HR yet).
Finding that problem, matching it to past work and producing a clean 2-page CV
takes an hour per ad. Past ads and the CVs sent for them end up scattered, so
nothing can be looked up or reused.

## Who has it
| Who | What they need |
|---|---|
| A job seeker applying to several roles a week (one user for now) | Every ad stored in the same format, with its real problem, keywords and red flags read out |
| | A tailored 2-page CV per ad that leads with that problem and gets past ATS keyword checks |
| | Every CV version kept and findable later, with what each one cost |

## Top three journeys
1. **Add an ad.** Paste the ad (the first line is an optional label) → Save → in about 10 seconds the stored ad shows its basics, 1–3 ranked problems (each with confidence and the exact quote it comes from), keywords and red flags. The raw ad is always kept.
2. **Create a CV.** On an ad → Create CV → a review step shows the problems and keywords, plus a box for a final note → Generate → a 2-page A4 CV in MD and PDF appears as a new version under the ad. Nothing is overwritten.
3. **Look back.** Find a past ad by searching → open its CV versions → download one. In Settings, see the Claude spend for today, this week, this month and all time.

## How we'll know it works
| Measure | Target, in a time window | How it is read | When it is read |
|---|---|---|---|
| Every PDF is exactly 2 A4 pages | 100% of CVs | Page count checked at Generate; a failure is shown, never saved silently | Every Generate; automated test |
| The PDF is ATS-readable | 100% of CVs: text pulled from the PDF holds the ad's top-3 keywords in the ad's exact wording | The same check at Generate | Every Generate; automated test |
| Paste to downloaded CV | Median ≤ 3 min, review time included, per month | Ad created time vs first CV version time | Feature 1 done, then monthly |
| First draft is usable | ≤ 2 versions per ad on average, per month | Versions per ad | Monthly |
| CVs judged good | ≤ 20% of CVs flagged "Not good" per month; a CV downloaded and not flagged within 7 days counts as good | "Not good" flags (with a reason) on CV versions | Monthly |
| Cost per CV | ≤ $0.25 average, per week | Usage view average | Weekly |

## Not in the first version
- Search as you type, accordion rows, pills, expand/collapse all: safe because a newest-first list with a basic full-text box works at low ad counts; revisit when there are more than 30 ads.
- Uploading many reference CVs (PDF/DOCX/MD) with text extraction: safe because one reference CV pasted as text gives the CV its proof; revisit when Feature 1 is done.
- Match section (proof per problem and keyword, gaps marked): safe because the CV prompt reads the reference CV directly; revisit when ads average more than 2 CV versions.
- CV design 2 (Problem-first): safe because design 1 (Classic) covers the need; revisit when the 2-page and ATS checks hold for 10 CVs in a row.
- Application status and interview rate: safe because the rate means little before about 20 applications; revisit at the start of Feature 2.
- Ads in languages other than English: safe because the first version's ads are English, and search stems words by English rules; revisit when the first non-English ad is to be stored.
- Sign-up for more users, billing, designs 3 and 4, mobile app: safe because there is one user; revisit when a second user is wanted.

## Smallest working version
Feature 1, after the walking skeleton, runs end to end from pasting an ad to downloading a CV:
- Login, and an API key stored encrypted on the server and never sent back to the browser.
- Paste an ad → analysis stored in the full format above, as checked JSON.
- A newest-first list of ads with a basic full-text search box.
- One reference CV, pasted as text in Settings.
- Create CV: review step → design 1 (Classic) → MD + PDF. Each PDF is written once and kept unchanged, and each Generate makes a new version.
- A "Not good" button on each CV version, with a reason (wrong main problem, wrong keywords, too long, wording, other) and an optional note.
- A Usage view in Settings: spend for today, this week (starting Monday) and this month in the owner's configured timezone, plus all time; split into analyses and CVs; average cost per call; which model answered each call; spend against the caps. Each CV version shows its own cost.

Feature 2 adds the full search screen, uploads of many reference CVs, the Match section, design 2 and application status.

## Load
| What | At launch | In a year | Where the number came from |
|---|---|---|---|
| Users | 1 | 1 | Single login; more users are out of scope |
| Ads | 4 | ~250 | Launch: 4 sample ads. Year: an estimate of ~5 ads a week during an active job search |
| Searches per day | ~5 | ~20 | Estimate for one person looking up past ads |
| CV versions | ~8 | ~500 | ~2 per ad: a first draft plus one redo after a final note |
| Claude calls | ~12 | ~750 | One per analysis plus one per CV version |
| Peak requests per second | < 1 | < 1 | One user, one request at a time |
| Rows and storage per year | — | ~1,500 rows, ~50 MB of PDFs | Ads + CV versions + one usage row per call; ~100 KB per 2-page PDF |
| Monthly cost at this load | ~$6 | ~$12 | Claude ~$7 at a year's volume (~$0.08 per analysis, ~$0.12 per CV, at Claude Opus 5.5 list prices with estimated token counts, to be replaced by the Usage view figures) + file storage ~$5; the existing server adds nothing |

## Budgets
| Budget | Target | At what load | How it is checked |
|---|---|---|---|
| Speed: search (95% faster than) | 200 ms on the server | 250 ads, 20 searches a day | Per-endpoint duration from the request logs |
| Speed: ad analysis (95% faster than) | 30 s, with progress shown (typically ~10 s) | 5 ads a week | Duration stored per Claude call |
| Speed: Create CV incl. PDF (95% faster than) | 90 s, with progress shown | 10 CVs a week | Duration stored per Claude call plus render time |
| Uptime | 99% a month; automatic restart on crash; nobody paged | One user | Health check |
| Monthly cost cap | Claude: alert at $20, no new calls at $50 (counted by the app), plus a spend limit set on the API key itself | ~$7 expected; a busy month ~$20–30 | Usage view; the API key's own spend limit as the backstop |
| Accessibility | WCAG 2.2 AA for the app; every PDF keeps a real text layer | All screens and every PDF | Automated accessibility check in the browser tests; the ATS text check at Generate |
