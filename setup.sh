#!/bin/sh
set -e

REGISTRY_URL="${REGISTRY_URL:-http://backend:8080}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

apk add --no-cache curl jq >/dev/null 2>&1

# Login (endpoint is allowlisted even when GUEST_ACCESS_ENABLED=false)
echo "==> Logging in as $ADMIN_USER..."
TOKEN=$(curl -sf -X POST "$REGISTRY_URL/api/v1/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Authentication failed"
  exit 1
fi
echo "  Token obtained"

# Create hosted Maven repository
echo "==> Creating Maven repository..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$REGISTRY_URL/api/v1/repositories" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"test-maven","name":"Test Maven","format":"maven","repo_type":"local","is_public":true}')

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo "  Repository 'test-maven' created (HTTP $HTTP_CODE)"
else
  echo "  Repository may already exist (HTTP $HTTP_CODE, ignoring)"
fi

# Deploy a test artifact via PUT to /maven/{repo_key}/...
echo "==> Deploying test artifact..."
AUTH="Authorization: Bearer $TOKEN"

# Artifact coordinates
GROUP_PATH="com/test/dummy"
ARTIFACT_ID="dummy"
VERSION="1.0"
REPO_URL="$REGISTRY_URL/maven/test-maven"

# Create artifact content
mkdir -p /tmp/artifact

cat > /tmp/artifact/dummy-1.0.pom << 'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.test</groupId>
    <artifactId>dummy</artifactId>
    <version>1.0</version>
</project>
POM

echo "dummy jar content" > /tmp/artifact/dummy-1.0.jar

# SHA1 checksums
sha1sum /tmp/artifact/dummy-1.0.pom | cut -d' ' -f1 > /tmp/artifact/dummy-1.0.pom.sha1
sha1sum /tmp/artifact/dummy-1.0.jar | cut -d' ' -f1 > /tmp/artifact/dummy-1.0.jar.sha1

# maven-metadata.xml at group/artifact level
cat > /tmp/artifact/maven-metadata.xml << 'META'
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>com.test</groupId>
  <artifactId>dummy</artifactId>
  <versioning>
    <latest>1.0</latest>
    <release>1.0</release>
    <versions>
      <version>1.0</version>
    </versions>
    <lastUpdated>20260101000000</lastUpdated>
  </versioning>
</metadata>
META
sha1sum /tmp/artifact/maven-metadata.xml | cut -d' ' -f1 > /tmp/artifact/maven-metadata.xml.sha1

# Upload POM
echo "  Uploading POM..."
curl -s -o /dev/null -w "  POM upload: HTTP %{http_code}\n" -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/dummy-1.0.pom \
  "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.pom"

curl -s -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/dummy-1.0.pom.sha1 \
  "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.pom.sha1" >/dev/null

# Upload JAR
echo "  Uploading JAR..."
curl -s -o /dev/null -w "  JAR upload: HTTP %{http_code}\n" -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/dummy-1.0.jar \
  "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.jar"

curl -s -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/dummy-1.0.jar.sha1 \
  "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.jar.sha1" >/dev/null

# Upload maven-metadata.xml
echo "  Uploading maven-metadata.xml..."
curl -s -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/maven-metadata.xml \
  "$REPO_URL/$GROUP_PATH/maven-metadata.xml" >/dev/null

curl -s -X PUT -H "$AUTH" \
  --data-binary @/tmp/artifact/maven-metadata.xml.sha1 \
  "$REPO_URL/$GROUP_PATH/maven-metadata.xml.sha1" >/dev/null

echo "  Artifact deployed: com.test:dummy:1.0"
echo ""
echo "==> Verifying artifact with curl..."
AUTH_BASIC="Authorization: Basic $(echo -n "$ADMIN_USER:$ADMIN_PASS" | base64)"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "$AUTH_BASIC" \
  "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.jar" 2>/dev/null)

if [ "$HTTP_CODE" = "200" ]; then
  echo "  Verification: artifact is accessible (HTTP $HTTP_CODE)"
else
  echo "  WARNING: artifact verification returned HTTP $HTTP_CODE"
fi

# Also show what happens WITHOUT auth (the 401 with no WWW-Authenticate)
echo ""
echo "==> Demonstrating 401 without WWW-Authenticate header..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.jar")
echo "  Without auth: HTTP $HTTP_CODE (expected 401)"
HEADERS=$(curl -s -D - -o /dev/null "$REPO_URL/$GROUP_PATH/$VERSION/dummy-1.0.jar" 2>&1 | head -20)
echo "  Response headers:"
echo "$HEADERS" | head -10

echo ""
echo "==> Setup complete"
touch /tmp/.setup-done
tail -f /dev/null
