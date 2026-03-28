#!/bin/bash
# Updates the nanoc-shared-scripts submodule to the latest commit and commits the change.
# Must be run from the project root (directory containing nanoc.yaml).

set -e

# Colours
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure we're in a project root with nanoc.yaml
if [ ! -f "nanoc.yaml" ]; then
    echo -e "${RED}Error: nanoc.yaml not found. Run this script from the project root.${NC}"
    exit 1
fi

# Ensure the submodule directory exists
if [ ! -d "nanoc-shared-scripts" ]; then
    echo -e "${RED}Error: nanoc-shared-scripts directory not found. Is the submodule added?${NC}"
    exit 1
fi

# Check for uncommitted changes in the working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${RED}Error: You have uncommitted changes. Please commit or stash them first.${NC}"
    exit 1
fi

echo "Updating nanoc-shared-scripts submodule..."
git submodule update --remote nanoc-shared-scripts

# Check if there's actually a change to commit
if git diff --quiet nanoc-shared-scripts; then
    echo -e "${GREEN}Already up to date. Nothing to commit.${NC}"
    exit 0
fi

git add nanoc-shared-scripts
git commit -m "Update shared scripts to latest"

echo -e "${GREEN}Done. nanoc-shared-scripts updated and committed.${NC}"
