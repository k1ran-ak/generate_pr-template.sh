#!/bin/bash

# Function to fetch API key from macOS Keychain
get_api_key() {
  security find-generic-password -a "$USER" -s "OpenAI_API_Key" -w 2>/dev/null
}

# Retrieve API key
api_key=$(get_api_key)

if [ -z "$api_key" ]; then
  echo "Error: API key not found in Keychain. Please add it using:"
  echo 'security add-generic-password -a "$USER" -s "OpenAI_API_Key" -w "your_api_key"'
  exit 1
fi

# Get the current branch name
current_branch=$(git rev-parse --abbrev-ref HEAD)

if [ -z "$current_branch" ]; then
  echo "Error: Could not determine the current branch. Ensure you are in a Git repository."
  exit 1
fi

# Set the default target branch (change 'main' if your default branch differs)
# for develop: orgin/develop, for release: orgin/release
target_branch="main"

# Extract JIRA issue ID (part before the first '/')
jira_issue_id=$(echo "$current_branch" | cut -d '/' -f 1)

# Get the last 5 commit messages for the current branch
commit_messages=$(git log "$target_branch..$current_branch" --oneline)

if [ -z "$commit_messages" ]; then
  echo "Error: No recent commits found for the branch '$current_branch'."
  exit 1
fi

## Escape commit messages for valid JSON
#escaped_commit_messages=$(echo "$commit_messages" | jq -R . | jq -s .)

# Combine the commit messages into a single string
formatted_commit_messages=$(echo "$commit_messages" | tr '\n' ' ')

echo "Target Branch: $target_branch"
echo "Current Branch: $current_branch"

# Generate PR description using ChatGPT API
echo "Generating PR description..."
response=$(curl -s -X POST https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $api_key" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant for writing pull request descriptions."},
      {"role": "user", "content": "For the given commit messages generate a Pull request description, avoid using commit messages exactly rather give a meaningful yet proper PR description, description should be in points - '"$formatted_commit_messages"'. "}
    ],
    "temperature": 1,
    "max_tokens": 2048,
    "top_p": 1,
    "frequency_penalty": 0,
    "presence_penalty": 0
  }')

description=$(echo "$response" | jq -r '.choices[0].message.content')

if [ -z "$description" ] || [ "$description" == "null" ]; then
  echo "Error: Failed to generate PR description. Response from API:"
  echo "$response"
  exit 1
fi

# Ask if there are considerations
echo "Are there any considerations for this PR? (y/n): "
read -n 1 has_considerations
echo # Move to a new line after input

if [[ $has_considerations == "y" ]]; then
    echo "Does this PR require any major changes in the consumer? (y/n):"
    read -n 1 major_changes
    echo # Move to a new line after input
    if [[ $major_changes == "y" ]]; then
        major_changes="Yes"
    else
        major_changes="N/A"
    fi

    echo "Does this PR require migration? (y/n):"
    read -n 1 requires_migration
    echo # Move to a new line after input
    if [[ $requires_migration == "y" ]]; then
        requires_migration="Yes"
    echo "What type of migration is required?"
    echo "1) RESYNC"
    echo "2) FORCELOGOUT"
    echo "3) Other"
    echo "Enter your choice (1/2/3):"
    read -n 1 migration_type
    echo # Move to a new line after input
    case $migration_type in
        1)
            migration_type="RESYNC"
            ;;
        2)
            migration_type="FORCELOGOUT"
            ;;
        3)
            read -p "Specify the migration type: " migration_type
            ;;
        *)
            migration_type="N/A"
            echo "Invalid choice. Marking as N/A."
            ;;
    esac
    else
        requires_migration="N/A"
        migration_type="N/A"
        migration_reason="N/A"
    fi

    echo "Are there any specific fallbacks? Select an option:"
    echo "1) Revert"
    echo "2) Feature Flag"
    echo "3) Other"
    echo "Enter your choice (1/2/3):"
    read -n 1 fallback_choice
    echo # Move to a new line after input
    case $fallback_choice in
        1)
            fallbacks="Revert"
            ;;
        2)
            fallbacks="Feature Flag"
            ;;
        3)
            read -p "Specify the fallback type: " fallbacks
            ;;
        *)
            fallbacks="N/A"
            echo "Invalid choice. Marking as N/A."
            ;;
    esac

    echo "Are there any inter-project dependencies? If yes then please specify"
    read dependencies
    if [[ -z $dependencies ]]; then
        dependencies="N/A"
    fi
else
    major_changes="N/A"
    requires_migration="N/A"
    migration_type="N/A"
    migration_reason="N/A"
    fallbacks="N/A"
    dependencies="N/A"
fi


# Interactive checklist
questions=(
    "New and updated code is logically covered with unit tests and does not violate other product requirements"
    "New and updated code do not trigger linter warnings or errors"
    "Changes are made according to Organization Style guide and other Coding Standards"
    "Required documentation is added and/or updated"
    "New and updated strings are using localized keys (are not hardcoded)"
    "New extension/helper/code is not duplicated"
    "Required Sentry Logs (or) Breadcrumbs are added"
    "Did I remove all unnecessary logging and print statements"
    "Thread-Safety is considered when utilizing Shared resources"
    "The code has been thoroughly reviewed for potential security vulnerabilities"
    "Sensitive information is not exposed in code or configuration"
)

echo "Checklist:"
for item in "${questions[@]}"; do
    echo "- [ ] $item"
done

echo "Do you want to mark all checklist items as 'yes' by default? (y/n): "
read -n 1 default_apply
echo # Move to a new line after input

answers=($(for _ in "${questions[@]}"; do echo "no"; done))

if [[ $default_apply == "y" ]]; then
    for i in "${!answers[@]}"; do
        answers[$i]="yes"
    done
else
    for ((i = 0; i < ${#questions[@]}; i++)); do
    echo "Mark '${questions[i]}' as completed? (y/n):"
    read -n 1 answer # Read a single character input without pressing Enter
    echo # Move to a new line after input
    if [[ $answer == "y" ]]; then
        answers[$i]="- [X] ${questions[i]}"
    else
        answers[$i]="- [ ] ${questions[i]}"
    fi
done

fi

# Create PR template
cat > PR_TEMPLATE.md <<EOL
# Description
JIRA issue: $jira_issue_id
<!--github automatically converts JIRA IDs into clickable links-->
<!--Add reference documentations and description of changes in this PR that gives additional context to reviewers-->
Branch: \`$current_branch\`
Merging into: \`$target_branch\`

$description

### Visual reference
<!--Add screenshots, video recording or other visual reference for changes if applicable-->

# How to Test
<!--Add testing steps needed to verify changes-->

### Considerations (if any)
- Does it require any major changes in the consumer: ${major_changes}
- Does it require Migration: ${requires_migration}
    - Type of Migration: ${migration_type}
    - Why this migration is required: ${migration_reason}
- Specific fallback (if any): ${fallbacks}
- Inter-project dependencies: ${dependencies}

### Checklist
$(for ((i = 0; i < ${#questions[@]}; i++)); do
    if [[ ${answers[i]} == "yes" ]]; then
        echo "- [X] ${questions[i]}"
    else
        echo "- [ ] ${questions[i]}"
    fi
done)
EOL

cat PR_TEMPLATE.md | pbcopy
echo "PR copied to clipboard. Paste it in the GitHub PR form."
