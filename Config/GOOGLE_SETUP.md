# Google connections

Hestrel uses the official Google Sign-In iOS SDK. Gmail, Calendar and Drive tools run on the device and are offered to all model providers as ordinary function tools. No OpenAI API key, hosted connector, or MCP server is required. Credentials are stored by the SDK in Keychain; only account metadata and the user's service switches are saved in `google-connection.json`.

## Register Hestrel

1. Create/select a Google Cloud project and enable **Gmail API**, **Google Calendar API**, and **Google Drive API**.
2. Configure the Google Auth Platform consent screen. During testing, add the Google accounts that will use Hestrel as test users.
3. Create an OAuth client of type **iOS**, with bundle identifier **me.jach.hestrel-ios**.
4. Run the helper with the public iOS client ID:

   ```sh
   python3 Config/configure-google.py YOUR_CLIENT_ID.apps.googleusercontent.com
   ```

   It creates the ignored `Config/Google.local.xcconfig`, including the reversed URL scheme. Both Debug and Release configurations include this file. No client secret is needed or embedded in the app.
5. Build and install. Open **Plugins** and connect each service you want to use. Each asks for its own read-only scope. The same account is used for all three services.

Without a client ID, the rest of Hestrel works and Connect reports that Google connections are not configured in this build. No placeholder credentials or working sign-in are implied.

## Permissions

- Gmail: `https://www.googleapis.com/auth/gmail.readonly`
- Calendar: `https://www.googleapis.com/auth/calendar.readonly`
- Drive: `https://www.googleapis.com/auth/drive.readonly`

For distribution outside test users, complete the verification required by Google for these scopes. Google controls token expiry and Workspace access policies.

The tools search/read mail, list calendars and events, search Drive and inspect file metadata, and export Docs/Slides as text or the first Sheets sheet as CSV. They do not send mail, modify events, edit files, or download binary attachments. Google response bodies are capped at 2 MB; document and message text is limited to 40,000 characters. Search/list endpoints return pagination tokens.

## Device verification

1. Connect Gmail, Calendar and Drive. Decline one service's consent and verify the other services stay connected.
2. With each provider, request a recent email search, calendar events for a concrete time range, and a Drive document search/read. The selected model must support function calling.
3. Turn a service off and check its tools disappear for all providers.
4. Restart Hestrel and verify token refresh and enabled-service persistence.
5. Disconnect Google. All tools should disappear immediately; successful revocation removes the SDK credentials.

Official references: [iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating), [API access and incremental scopes](https://developers.google.com/identity/sign-in/ios/api-access).
