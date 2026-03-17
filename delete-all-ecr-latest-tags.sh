#!/bin/bash
#
# ECR の全リポジトリから latest タグを一律で削除するスクリプト
#
# Usage:
#   ./script/delete-all-ecr-latest-tags.sh [OPTIONS]
#
# Options:
#   --profile NAME      AWS プロファイル (default: YOUR_PROFILE)
#   --region REGION     AWS リージョン (default: ap-northeast-1)
#   --target LIST       削除対象のリポジトリ名（カンマ区切りで複数指定可。ワイルドカード対応。指定時は対象のみ処理）
#   --exclude LIST      削除対象から除外するリポジトリ名（カンマ区切りで複数指定可。ワイルドカード対応）
#   --dry-run           削除せずに対象のみ表示
#   -h, --help          このヘルプを表示
#

set -eu

readonly TAG_LATEST="latest"
AWS_PROFILE="YOUR_PROFILE"
REGION="ap-northeast-1"
TARGET_REPOS=()
EXCLUDE_REPOS=()
DRY_RUN=false

function usage() {
  sed -n '2,/^$/p' "$0" | sed '$d'
  return 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --target)
      IFS=',' read -r -a parts <<< "$2"
      TARGET_REPOS+=("${parts[@]}")
      shift 2
      ;;
    --exclude)
      IFS=',' read -r -a parts <<< "$2"
      EXCLUDE_REPOS+=("${parts[@]}")
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

function aws_ecr() {
  aws ecr "$@" --region "$REGION" --profile "$AWS_PROFILE" --no-cli-pager
}

# Verify AWS credentials (exit on not logged in, STS timeout, etc.)
# Use set +e so we can capture exit code and print error before exiting
set +e
sts_err=$(aws --no-cli-pager sts get-caller-identity --profile "$AWS_PROFILE" 2>&1)
sts_ret=$?
set -e
if [[ $sts_ret -ne 0 ]]; then
  echo "Error: Not logged in to AWS (profile: ${AWS_PROFILE:-}). Credentials may be expired or STS request timed out." >&2
  [[ -n "${sts_err:-}" ]] && echo "$sts_err" >&2
  exit 1
fi

ALL_REPOS=($(aws_ecr describe-repositories --query 'repositories[].repositoryName' --output text))
REPO_NAMES=()
for repo in "${ALL_REPOS[@]}"; do
  # --target: 指定時はパターンに一致するもののみ対象
  if [[ ${#TARGET_REPOS[@]} -gt 0 ]]; then
    match=false
    for pattern in "${TARGET_REPOS[@]}"; do
      if [[ "$repo" == $pattern ]]; then
        match=true
        break
      fi
    done
    [[ "$match" == false ]] && continue
  fi

  # --exclude: パターンに一致するものを除外
  if [[ ${#EXCLUDE_REPOS[@]} -gt 0 ]]; then
    skip=false
    for pattern in "${EXCLUDE_REPOS[@]}"; do
      if [[ "$repo" == $pattern ]]; then
        skip=true
        break
      fi
    done
    [[ "$skip" == true ]] && continue
  fi

  REPO_NAMES+=("$repo")
done

if [[ ${#REPO_NAMES[@]} -eq 0 ]]; then
  echo "No repositories found."
  exit 0
fi

DELETED_COUNT=0

for repo in "${REPO_NAMES[@]}"; do
  digest=$(aws_ecr describe-images \
    --repository-name "$repo" \
    --image-ids imageTag="$TAG_LATEST" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || true)

  if [[ -z "$digest" || "$digest" == "None" ]]; then
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] Would delete: $repo (tag: $TAG_LATEST, digest: $digest)"
    ((DELETED_COUNT++)) || true
    continue
  fi

  if aws_ecr batch-delete-image \
    --repository-name "$repo" \
    --image-ids imageDigest="$digest"; then
    echo "Deleted: $repo (tag: $TAG_LATEST)"
    ((DELETED_COUNT++)) || true
  else
    echo "Failed to delete: $repo (tag: $TAG_LATEST)" >&2
  fi
done

echo ""
echo "Done. Deleted latest tag from $DELETED_COUNT repository(ies)."
