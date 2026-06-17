#!/bin/bash
# Maven Auth Reproduction Test
#
# Demonstrates the bug: Maven fails to authenticate against Artifact Keeper
# when AK_GUEST_ACCESS_ENABLED=false because the 401 response lacks
# WWW-Authenticate header, so Maven never retries with credentials.
#
# Fix: aether.connector.http.preemptiveAuth=true

set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-http://backend:8080}"
REGISTRY_USER="${REGISTRY_USER:-admin}"
REGISTRY_PASS="${REGISTRY_PASS:-admin}"

MAVEN_REPO_URL="${REGISTRY_URL}/maven/test-maven"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }

echo "============================================================"
echo "  Maven + Artifact Keeper Auth Reproduction"
echo "============================================================"
echo "  Registry: $REGISTRY_URL"
echo "  Repo URL: $MAVEN_REPO_URL"
echo "  User:     $REGISTRY_USER"
echo "============================================================"
echo ""

# ===== DEMO: curl without auth shows 401 with no WWW-Authenticate =====
echo "---[ Demo: curl WITHOUT auth (root cause) ]---"
HEADERS=$(curl -s -D - -o /dev/null "$MAVEN_REPO_URL/com/test/dummy/1.0/dummy-1.0.jar" 2>&1)
echo "$HEADERS" | head -10
echo "  (no WWW-Authenticate header — Maven cannot retry)"
echo ""

# ===== Prepare common Maven project =====
WORK_DIR="$(mktemp -d)"
cd "$WORK_DIR"

cat > pom.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.test</groupId>
    <artifactId>test-consumer</artifactId>
    <version>1.0</version>
    <repositories>
        <repository>
            <id>test-registry-mirror</id>
            <url>$MAVEN_REPO_URL</url>
        </repository>
    </repositories>
    <dependencies>
        <dependency>
            <groupId>com.test</groupId>
            <artifactId>dummy</artifactId>
            <version>1.0</version>
        </dependency>
    </dependencies>
</project>
EOF

# Maven settings with server credentials and a mirror that EXCLUDES central
# (so Maven plugins still resolve from Central without going through AK)
mkdir -p ~/.m2
cat > ~/.m2/settings.xml << EOF
<settings>
  <servers>
    <server>
      <id>test-registry-mirror</id>
      <username>$REGISTRY_USER</username>
      <password>$REGISTRY_PASS</password>
    </server>
  </servers>
  <mirrors>
    <mirror>
      <id>test-registry-mirror</id>
      <!-- mirror everything EXCEPT central, so plugin resolution still works -->
      <mirrorOf>*,!central</mirrorOf>
      <url>$MAVEN_REPO_URL</url>
    </mirror>
  </mirrors>
  <profiles>
    <profile>
      <id>test-profile</id>
      <properties>
        <maven.artifact.checksum.policy>IGNORE</maven.artifact.checksum.policy>
      </properties>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>test-profile</activeProfile>
  </activeProfiles>
</settings>
EOF

# ===== Test 1: WITHOUT preemptive auth =====
echo "---[ Test 1: mvn dependency:resolve WITHOUT preemptive auth ]---"

# Ensure NO preemptive auth config is present and no cached artifact
rm -rf "$WORK_DIR/.mvn"
rm -rf ~/.m2/repository/com/test/dummy

set +e
MVN_OUTPUT=$(mvn dependency:resolve -U 2>&1)
MVN_EXIT=$?
set -e

if echo "$MVN_OUTPUT" | grep -qi "401\|unauthorized\|authentication failed"; then
    pass "Test 1: failed WITH 401 (expected — the bug)"
elif [ $MVN_EXIT -ne 0 ]; then
    # Check if it failed due to 401 for our dummy artifact specifically
    if echo "$MVN_OUTPUT" | grep -qi "401.*dummy\|dummy.*401"; then
        pass "Test 1: dummy artifact got 401 (expected — the bug)"
    else
        fail "Test 1: unexpected failure. Output:"
        echo "$MVN_OUTPUT" | head -40
    fi
else
    fail "Test 1: succeeded (unexpected)"
fi

echo ""

# ===== Test 2: WITH preemptive auth =====
echo "---[ Test 2: mvn dependency:resolve WITH preemptive auth ]---"

cd "$WORK_DIR"
rm -rf ~/.m2/repository/com/test/dummy

# Create .mvn/maven.config with the preemptive auth setting (production fix approach)
mkdir -p .mvn
cat > .mvn/maven.config << 'EOF'
-Daether.connector.http.preemptiveAuth=true
EOF

set +e
MVN_OUTPUT=$(mvn dependency:resolve -U 2>&1)
MVN_EXIT=$?
set -e

if [ $MVN_EXIT -eq 0 ]; then
    pass "Test 2: succeeded WITH preemptive auth (expected — the fix)"
else
    fail "Test 2: failed WITH preemptive auth. Output:"
    echo "$MVN_OUTPUT" | head -40
fi

echo ""
echo "============================================================"
echo "  Results: $PASSED passed, $FAILED failed"
echo "============================================================"

rm -rf "$WORK_DIR"

[ "$FAILED" -eq 0 ]
