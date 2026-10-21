#!/usr/bin/env bash
# Одноразовая настройка GitHub-процессов для discenss/mental.
# Запускать владельцем репозитория (admin) ПОСЛЕ того, как .github/ влит в main:
#   gh auth login            # если ещё не залогинены
#   gh auth refresh -s project
#   ./scripts/github-setup.sh
# Скрипт идемпотентен: повторный запуск обновляет, а не дублирует.
set -uo pipefail

REPO="${REPO:-discenss/mental}"
OWNER="${REPO%%/*}"
PROJECT_TITLE="${PROJECT_TITLE:-Verge}"
warn() { echo "⚠️  $*" >&2; }
ok()   { echo "✓ $*"; }

command -v gh >/dev/null || { echo "Нужен gh: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Сначала: gh auth login"; exit 1; }

echo "== Настройки репозитория"
gh api -X PATCH "repos/$REPO" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=true -F allow_update_branch=true \
  -F has_issues=true -F has_projects=true -F has_wiki=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null \
  && ok "squash-only, авто-удаление веток, issues/projects включены" || warn "не удалось обновить настройки репозитория"

echo "== Безопасность"
gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1 && ok "Dependabot alerts" || warn "Dependabot alerts"
gh api -X PUT "repos/$REPO/automated-security-fixes" >/dev/null 2>&1 && ok "Dependabot security updates" || warn "Dependabot security updates"
gh api -X PATCH "repos/$REPO" --input - >/dev/null 2>&1 <<'JSON' && ok "Secret scanning + push protection" || warn "Secret scanning (для приватного репо нужен GitHub Advanced Security / Team)"
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON

echo "== Labels"
count=$(jq length .github/labels.json)
for i in $(seq 0 $((count-1))); do
  name=$(jq -r ".[$i].name" .github/labels.json)
  color=$(jq -r ".[$i].color" .github/labels.json)
  desc=$(jq -r ".[$i].description" .github/labels.json)
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force >/dev/null 2>&1 \
    && ok "label $name" || warn "label $name"
done

echo "== Защита main (ruleset)"
RULESET_JSON=$(cat <<'JSON'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [
    {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}
  ],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 1,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": true,
      "allowed_merge_methods": ["squash"]
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": true,
      "required_status_checks": [
        {"context": "backend"}, {"context": "bot"}, {"context": "docker"},
        {"context": "secrets"}, {"context": "pr-title"}
      ]
    }}
  ]
}
JSON
)
existing=$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name=="Protect main") | .id' 2>/dev/null | head -1)
if [ -n "$existing" ]; then
  echo "$RULESET_JSON" | gh api -X PUT "repos/$REPO/rulesets/$existing" --input - >/dev/null \
    && ok "ruleset обновлён" || warn "не удалось обновить ruleset"
else
  echo "$RULESET_JSON" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null \
    && ok "ruleset создан" \
    || warn "ruleset не создан. Для ПРИВАТНОГО репо на бесплатном плане защита веток недоступна (нужен GitHub Pro/Team) — либо сделайте репо публичным, либо апгрейд."
fi

echo "== Борда (GitHub Projects)"
if ! gh auth status 2>&1 | grep -q "project"; then
  warn "у токена нет scope 'project'. Выполните: gh auth refresh -s project  — и запустите скрипт снова"
else
  num=$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title==\"$PROJECT_TITLE\") | .number" 2>/dev/null | head -1)
  if [ -z "$num" ]; then
    num=$(gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json --jq .number)
    ok "проект создан (#$num)"
  else
    ok "проект уже есть (#$num)"
  fi
  gh project link "$num" --owner "$OWNER" --repo "$REPO" >/dev/null 2>&1 && ok "проект привязан к репозиторию"
  gh project field-create "$num" --owner "$OWNER" --name "Area" --data-type SINGLE_SELECT \
    --single-select-options "backend,bot,ios,content,infra,docs" >/dev/null 2>&1 && ok "поле Area"
  gh project field-create "$num" --owner "$OWNER" --name "Priority" --data-type SINGLE_SELECT \
    --single-select-options "P0,P1,P2,P3" >/dev/null 2>&1 && ok "поле Priority"

  # Колонки Status: Backlog / Todo / In progress / In review / Done
  pid=$(gh project view "$num" --owner "$OWNER" --format json --jq .id)
  fid=$(gh project field-list "$num" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .id')
  gh api graphql -f query='
    mutation($f:ID!){ updateProjectV2Field(input:{fieldId:$f, singleSelectOptions:[
      {name:"Backlog",color:GRAY,description:"Идеи и неразобранное"},
      {name:"Todo",color:BLUE,description:"Готово к работе"},
      {name:"In progress",color:YELLOW,description:"В работе"},
      {name:"In review",color:PURPLE,description:"PR ждёт ревью"},
      {name:"Done",color:GREEN,description:"Сделано"}]}){ projectV2Field{ ... on ProjectV2SingleSelectField{ id } } } }' \
    -f f="$fid" >/dev/null 2>&1 && ok "колонки Status" || warn "колонки Status настройте вручную"
  echo
  echo "Ещё вручную в UI (API не умеет): Project → ⋯ → Workflows:"
  echo "  • Auto-add to project (репо $REPO)  • Item closed → Done  • Pull request merged → Done"
  echo "  • Item added → Backlog  • Pull request opened → In review"
  echo "  Затем создайте view «Board» (Layout: Board, group by Status)."
fi
echo
echo "Готово."
