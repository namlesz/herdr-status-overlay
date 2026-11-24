# Agent instructions

## Pi tool workflow

- For `fetch_content` in `readable` mode, prefer a direct tool call. In `codemode`, keep the full response inside the script and print only `responseId` (and any error), not the page content.
- Read stored web content with `get_search_content`. For a bounded page, use `limit` (and `offset` if needed) without `findText`. For matching passages, use `findText` without `limit` or `offset`; those parameters are ignored in this mode. If printing matches from `codemode`, cap the output before passing it to `text()`.
- When several checks belong in one verification report, group them in one `bg_run` with the default completion notification. Report each check's result and return a nonzero exit status if any check fails. Keep unrelated background jobs separate.
