# Beatrix — private iPhone app

First version: secure pairing, authorized contact synchronization, assistant name,
greeting, instructions, voice, transcript email recipient/switch, and call history.
The app uses SwiftUI and requires iOS 17 or later. It understands limited Contacts
permission on iOS 18 or later. Credentials are stored in the device-only Keychain.

## Build on your Mac

1. Install full Xcode from the Mac App Store and open it once to finish setup.
2. Open `Beatrix.xcodeproj`.
3. In **Signing & Capabilities**, select your personal Apple development team.
   Change the bundle identifier if your account requires a unique one.
4. Connect your iPhone, enable Developer Mode if requested, select it as the
   destination, and press Run. Free personal signing may need periodic renewal.

The project is prepared without an Apple team ID or signing credentials. The unsigned iPhone build has been verified with Xcode. Signing, installation and
real-device testing remain required before considering it released.

## Pair with your server

The server must expose `/api/*` over HTTPS with a valid certificate. Use your
existing secure ingress or a private network with HTTPS. The app deliberately
rejects plain HTTP and does not bypass certificate verification. An ingress that
only forwards `/webhook` must also forward `/api/*` to Beassistant on port 8000.

On the Mac, from the Beassistant directory:

```sh
docker compose exec beassistant python management.py pair
```

Enter your HTTPS server base address and the generated code in the app. The code
is single-use and expires in 10 minutes. Do not put it or the resulting device
token in source control. To revoke all devices:

```sh
docker compose exec beassistant python management.py revoke-all
```

The app’s Disconnect button revokes that phone’s token on the server before
removing it from Keychain. If the server is unavailable, revoke it from the server
when reachable. There is no contact-data transfer until you authorize and sync.

## Contacts

The iPhone is the source; this version maintains one server snapshot. Authorized
names, phone numbers and email addresses are copied into local SQLite under
`data/companion.sqlite3`. No contact photos, birthdays or notes are requested.
Apple Contacts is never edited. A successful sync replaces the previous snapshot,
including deleting contacts no longer accessible to this phone. With limited
permission, the snapshot includes only selected contacts. Use one phone as the
source for this first version.

After the initial sync, foreground synchronization is enabled and only uploads
when the authorized snapshot changes. You can switch it off. iOS background sync
is not implemented. The app must be opened to propagate changes.

International numbers beginning with `+` or `00` are matched, and 10-digit French
national numbers are normalized to `+33`. Other national number regions need
explicit support later. Shared numbers match no name when ambiguous. Caller
number remains unverified SIP metadata; matching does not grant caller access to
assistant settings or contacts. Matched contact names appear in transcripts.

## Settings and privacy

Settings are saved to the existing config files and apply to subsequent calls.
The config mount is writable for this purpose. The API validates a fixed set of
fields; it exposes no arbitrary file paths and never returns SMTP passwords or
OpenAI credentials. SMTP host/login/password configuration stays on the server;
the app can change only the recipient and sending switch.

The management API and pairing state are implemented in `management.py`. Device
tokens are stored hashed in SQLite. Pairing attempts are rate-limited. All API
responses are marked `Cache-Control: no-store`. The owner token grants access to
settings, contacts and transcripts; protect paired devices accordingly.

Contact and transcript databases, credentials and personal instructions remain
excluded from GitHub. This is a private prototype: App Store distribution, multiple
assistants, contact editing, conflict resolution and continuous background sync
are outside this version.
