#Cloudflare Gateway Block Ads

Forked from jacobgelling/cloudflare-gateway-block-ads.
This version uses the HaGeZi Ultimate blocklist by default. It will automatically download the blocklist, split it into chunks, upload the chunks as Cloudflare Domains lists, and apply a Gateway policy to block them.

If you want a different blocklist, just change the blocklist URL in the script. No other modification is required.

Cloudflare currently enforces 300 lists and 300k total domains. If your chosen blocklist exceeds those limits, trim or switch to something below 300K domains (OISD Big/Small, 1Hosts Lite, HaGeZi Normal/Pro/Pro++, etc.)

How It Works

The script pulls the HaGeZi Ultimate list every hour, checks for changes, and only updates the Cloudflare lists if the source list has changed. This avoids pointless API calls.

Setup
Cloudflare

You need a Cloudflare Zero Trust account. The free tier works.
Create an API Token with Account.Zero Trust permissions.
Locate your Account ID from the Cloudflare dashboard URL.
Keep the token and ID ready for GitHub secrets.

GitHub

Fork this repository.
Add two repository secrets:

API_TOKEN set to your Cloudflare API token

ACCOUNT_ID set to your Cloudflare Account ID

Enable GitHub Actions with read and write workflow permissions.
