#!/bin/sh
# Build the Kyserai image and publish it to the Kyseros cloud service:
# upload the docker-save archive into the internal registry, then bind
# the returned reference onto this app's catalog entries, and bind the
# latest published AMD provider digest onto the AMD entry.
#
# Manifests reach the catalog through git plus the service's catalog
# sync (or dashboard authoring). Publish them first: a fresh catalog
# entry is not installable until its image is bound, so run this script
# right after the staging entries are published.
#
# Required environment (values recorded in kyseros-amd AGENTS.md):
#   KYSEROS_SERVICE_URL      default: http://updates.cloudlnk.cn:8080
#   KYSEROS_SERVICE_EMAIL    platform_admin login on the service
#   KYSEROS_SERVICE_PASSWORD its password

set -eu

cd "$(dirname "$0")/.."

usage() {
    cat >&2 <<'EOF'
Usage: scripts/publish.sh [options]

  --skip-build      upload the existing local image instead of building
  --sync            trigger a catalog sync and list pending entries
  --provider-ref    bind this explicit digest-pinned provider reference
                    instead of the latest amd-driver on the service
  --no-provider     leave the provider binding untouched

By default the script binds the newest kyseros-providers/amd-driver
upload recorded on the service (the digest the kyseros-amd publish.sh
printed) to the AMD catalog entry.
EOF
    exit 2
}

skip_build=0
run_sync=0
provider_mode=auto        # auto | explicit | skip
provider_ref=
while [ $# -gt 0 ]; do
    case $1 in
        --skip-build) skip_build=1 ;;
        --sync) run_sync=1 ;;
        --provider-ref) provider_mode=explicit
            [ $# -ge 2 ] || usage; provider_ref=$2; shift ;;
        --no-provider) provider_mode=skip ;;
        *) usage ;;
    esac
    shift
done

for variable in KYSEROS_SERVICE_EMAIL KYSEROS_SERVICE_PASSWORD; do
    eval "value=\${$variable:-}"
    [ -n "$value" ] || {
        echo "$variable is required (values in kyseros-amd AGENTS.md)" >&2
        exit 1
    }
done
service_url=${KYSEROS_SERVICE_URL:-http://updates.cloudlnk.cn:8080}
for tool in curl python3 docker; do
    command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

manifest_field() {
    # manifest_field <file> <key> -> value
    python3 -c \
        'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
        "$1" "$2"
}

image=$(manifest_field nvidia/app.json image)
image_repo=${image%%:*}
image_tag=${image#*:}
slugs=$(for variant in nvidia amd intel; do
    manifest_field "$variant/app.json" slug
done)
amd_slug=$(manifest_field amd/app.json slug)
provider_name=amd-driver

cookie=$(mktemp)
archive=$(mktemp)
response=$(mktemp)
trap 'rm -f "$cookie" "$archive" "$response"' EXIT

login_payload=$(python3 -c 'import json, os; print(json.dumps({
    "email": os.environ["KYSEROS_SERVICE_EMAIL"],
    "password": os.environ["KYSEROS_SERVICE_PASSWORD"]}))')
curl -fsS -c "$cookie" -H 'Content-Type: application/json' \
    -d "$login_payload" "$service_url/api/login" >/dev/null

if [ "$run_sync" -eq 1 ]; then
    curl -fsS -b "$cookie" -X POST "$service_url/api/catalog/sync" >/dev/null
    echo "Pending catalog entries:"
    curl -fsS -b "$cookie" "$service_url/api/catalog/staging" \
        | python3 -m json.tool
fi

if [ "$skip_build" -eq 0 ]; then
    [ -d ../kyserai ] || {
        echo "missing sibling kyserai checkout: ../kyserai" >&2
        exit 1
    }
    echo "Building $image"
    docker buildx build \
        --build-context kyserai=../kyserai \
        -t "$image" .
fi

echo "Uploading $image to $service_url"
docker save "$image" -o "$archive"
reference=$(curl -fsS -b "$cookie" \
    -F "file=@$archive;filename=$image_repo.tar;type=application/x-tar" \
    -F "slug=$image_repo" -F "version=$image_tag" \
    "$service_url/api/registry/images" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["reference"])')
echo "Uploaded: $reference"

post_bind() {
    # post_bind <label> <path> <json-payload>
    label=$1 path=$2 payload=$3
    if code=$(curl -sS -b "$cookie" -H 'Content-Type: application/json' \
            -d "$payload" -o "$response" -w '%{http_code}' \
            "$service_url$path"); then
        :
    else
        code=000
    fi
    if [ "$code" = 200 ]; then
        echo "bound: $label"
    else
        echo "binding $label failed (HTTP $code): $(cat "$response")" >&2
        return 1
    fi
}

failed=0
for slug in $slugs; do
    post_bind "image -> $slug" "/api/catalog/$slug/image" \
        "{\"reference\":\"$reference\"}" || failed=1
done

if [ "$provider_mode" != skip ]; then
    if [ "$provider_mode" = explicit ]; then
        provider_reference=$provider_ref
    else
        # The service upserts the provider row per repo:tag, so the
        # newest kyseros-providers/<name> row is the live digest.
        provider_reference=$(curl -fsS -b "$cookie" \
            "$service_url/api/registry/images" | python3 -c '
import json, sys
wanted = "kyseros-providers/" + sys.argv[1]
for image in json.load(sys.stdin).get("images", []):
    if image["repo"] == wanted:
        print(image["reference"] + "@" + image["digest"])
        break
' "$provider_name")
        [ -n "$provider_reference" ] || {
            echo "no $provider_name upload found on the service;" \
                "publish it first (kyseros-amd scripts/publish.sh)" \
                "or pass --provider-ref" >&2
            exit 1
        }
        echo "Latest provider: $provider_reference"
    fi
    post_bind "provider -> $amd_slug" "/api/catalog/$amd_slug/provider" \
        "{\"reference\":\"$provider_reference\"}" || failed=1
fi

if [ "$failed" -ne 0 ]; then
    echo "Some bindings failed. If a catalog entry does not exist yet," \
        "push the manifests, run the catalog sync and staging publish" \
        "(scripts/publish.sh --sync --skip-build shows the queue), then" \
        "rerun this script with --skip-build." >&2
    exit 1
fi
echo "Done: the image left this machine; the manifests stay in git."
