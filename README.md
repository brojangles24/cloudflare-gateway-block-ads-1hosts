<p align="center">
<img src="https://www.google.com/search?q=https://placehold.co/800x200/4F46E5/FFFFFF%3Ftext%3DCloudflare%2BGateway%2BAggregator%26font%3Dinter" alt="Cloudflare Gateway Aggregator Banner"/>
</p>

<p align="center">
<!-- IMPORTANT: You will need to replace 'YOUR_USERNAME/YOUR_REPONAME' with your actual GitHub username and repository name for these badges to work! -->
<!-- For example: brojangles24/cloudflare-gateway-block-ads-Aggregated -->
<img alt="GitHub last commit" src="https://www.google.com/search?q=https://img.shields.io/github/last-commit/YOUR_USERNAME/YOUR_REPONAME">
<img alt="GitHub Workflow Status" src="https://www.google.com/search?q=https://img.shields.io/github/actions/workflow/status/YOUR_USERNAME/YOUR_REPONAME/aggregate-lists.yml%3Fbranch%3Dmain%26label%3DList%2520Build%26logo%3Dgithub">
</p>

This version acts as a powerful list aggregator. By default, it combines the Hagezi Ultimate list, 1Hosts Lite, and OISD Small, deduplicates them, and then syncs the final, combined list to your Cloudflare Gateway.

You can easily customize your blocklist by editing the LIST_URLS array in the aggregator.sh script. Add, remove, or change any of the list URLs to create your own custom blend.

💡 How It Works

The script is pre-configured for Cloudflare's 300,000 domain limit (300 lists of 1,000 domains). If your chosen list combination exceeds this, the script will automatically fail to prevent errors.

The script runs on an automatic schedule (daily at 3:00 AM UTC, or whenever you run it manually). It aggregates your chosen lists and compares the new list to the one in your repository.

graph TD
    A[Start Daily Schedule] --> B{Check for List Changes};
    B -- Yes --> C[Download Lists];
    C --> D[Aggregate & Deduplicate];
    D --> E{Count > 300k?};
    E -- No --> F[Upload to Cloudflare];
    F --> G[Commit to Repo];
    E -- Yes --> H[Fail Workflow];
    B -- No --> I[Stop Early];
    G --> J[End];
    H --> J;
    I --> J;


If it detects changes, it will update all the Cloudflare lists via the API and commit the new list to your repository.

If there are no changes, it stops early to save resources and avoid pointless API calls.

🚀 Setup

1. Cloudflare

You need a Cloudflare Zero Trust account (the free tier works).

Locate your Account ID from the Cloudflare dashboard URL (it's the long string of characters after https://dash.cloudflare.com/).

Create an API Token by going to My Profile > API Tokens > Create Token.

Use the "Edit Cloudflare Zero Trust" template.

Give it Account.Zero Trust permissions.

Keep this token and your Account ID ready.

2. GitHub

Fork this repository.

Add Repository Secrets: In your forked repo, go to Settings > Secrets and variables > Actions and click New repository secret for each of the following:

API_TOKEN: Set to your Cloudflare API token.

ACCOUNT_ID: Set to your Cloudflare Account ID.

Enable Actions: Go to the Actions tab of your repository. You will see a prompt that says "Workflows aren't running on this fork." Click the I understand my workflows, go ahead and enable them button.

That's it! The script will now run automatically on its schedule. You can also trigger it manually by going to the Actions tab, clicking on "Aggregate Blocklists", and using the "Run workflow" dropdown.
