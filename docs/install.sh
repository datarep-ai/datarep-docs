#!/bin/sh
set -e

# datarep installer
# Usage: curl -sSL https://thyself-fyi.github.io/datarep-docs/install.sh | sh

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "${BOLD}datarep installer${NC}"
echo ""

# Check Python version
if ! command -v python3 >/dev/null 2>&1; then
    echo "${RED}Error: Python 3 is not installed.${NC}"
    echo "Install Python 3.10+ from https://python.org and try again."
    exit 1
fi

PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]; }; then
    echo "${RED}Error: Python >= 3.10 is required (found $PYTHON_VERSION).${NC}"
    echo "Install Python 3.10+ from https://python.org and try again."
    exit 1
fi

echo "  Python $PYTHON_VERSION ${GREEN}✓${NC}"

# Install datarep
echo ""
echo "Installing datarep..."
pip3 install datarep 2>&1 | tail -1

if ! command -v datarep >/dev/null 2>&1; then
    echo "${YELLOW}Warning: 'datarep' not found on PATH. You may need to add pip's bin directory to your PATH.${NC}"
    echo "Try: python3 -m datarep.cli init"
    exit 1
fi

echo "  datarep installed ${GREEN}✓${NC}"

# Initialize
echo ""
echo "Initializing datarep..."
datarep init
echo "  ~/.datarep/ ready ${GREEN}✓${NC}"

# Done
echo ""
echo "${GREEN}${BOLD}datarep is installed!${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Set your Anthropic API key:"
echo "     ${BOLD}export ANTHROPIC_API_KEY=\"sk-ant-...\"${NC}"
echo ""
echo "  2. Start the server:"
echo "     ${BOLD}datarep start${NC}"
echo ""
echo "  3. Register your app:"
echo "     ${BOLD}datarep app register <your-app-name>${NC}"
echo ""
echo "  4. Read the integration guide:"
echo "     https://thyself-fyi.github.io/datarep-docs/integration-guide/"
echo ""
