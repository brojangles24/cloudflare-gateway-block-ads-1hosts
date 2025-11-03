# Cloudflare Gateway Block Ads
A GitHub Actions script to automatically create and update Cloudflare Zero Trust Gateway ad blocking lists and policy.

The script works by periodically downloading the [OISD](https://oisd.nl/) big blocklist, splitting it into smaller chunks, uploading it to Cloudflare as multiple Domains lists, and then creating a policy that blocks all traffic to the domains in the lists.

It does not use the Cloudflare API unnecessarily as it only updates the Domains lists if the OSID blocklist has changed since the last run.

## Setup

### Cloudflare
First, you should ensure you have a Cloudflare account with a Zero Trust subscription. The free plan is sufficient for this script. You can sign up at [https://dash.cloudflare.com/sign-up/teams](https://dash.cloudflare.com/sign-up/teams).

You will then need to create a Cloudflare API token with the `Account.Zero Trust` permission. You can do this at [https://dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens).

You will also need to find your Cloudflare account ID. You can find this by going to the "Account Home" page in the Cloudflare dashboard and copying the account ID from the URL. It should be a 32 character string of letters and numbers.

Please take note of the API token and account ID for use in the next step.

### GitHub
Next you should make a fork of this project on GitHub. You can do this by clicking the "Fork" button in the top right of the page.

Next you must input the Cloudflare API token into your GitHub fork as a secret. You can do this by going to the "Settings" tab of your fork, then under the "Secrets and variables" dropdown in the sidebar, click "Actions". Click the "New repository secret" button and add a secret with the name `API_TOKEN` and the value of your Cloudflare API key. Create another secret with the name `ACCOUNT_ID` and the value of your Cloudflare account ID. 

Finally, you should ensure the GitHub actions are enabled for your fork. You can do this by going to the "Settings" tab of your fork, then under the "Actions" dropdown in the sidebar, click "General". Ensure the all actions and reusable workflows are permitted, and that workflow has read and write permissions.
