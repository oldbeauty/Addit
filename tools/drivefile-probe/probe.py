#!/usr/bin/env python3
"""What an app can see of a Drive folder under the drive.file scope.

Evidence for Google's minimum-scope review (2026-10-22): Google asked whether
Addit could use drive.file with the Picker instead of the full drive scope.
This runs the exact flow Google recommends for desktop and mobile apps (the
Picker opened through the OAuth URL with trigger_onepick=true; drive.file is
the only scope it allows) against a test OAuth client in a separate Cloud
project, then asks the Drive API what the app can actually reach.

    probe.py CLIENT.json pick
        Opens Google's consent + Picker in the browser. Pick an album folder
        (and, for the second test, the files inside it). Saves the grant, then
        runs `check` on whatever was picked.

    probe.py CLIENT.json check FOLDER_ID [FILE_ID=label ...]
        With the saved grant: lists the folder as the app sees it, and tries to
        open each FILE_ID (files inside the folder, or a file a collaborator
        added after the pick). Labels are for the printout only; an app that
        can't see a file can't learn its name either.

CLIENT.json is the "Desktop app" OAuth client's download. Standard library
only. The grant is kept in .token.json beside this script (gitignored).
"""
import base64, hashlib, http.server, json, os, secrets, sys, threading
import urllib.error, urllib.parse, urllib.request, webbrowser

SCOPE = "https://www.googleapis.com/auth/drive.file"
API = "https://www.googleapis.com/drive/v3"
TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".token.json")


def client(path):
    c = json.load(open(path))
    return c.get("installed") or c.get("web")


def post(url, fields):
    req = urllib.request.Request(url, urllib.parse.urlencode(fields).encode())
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def drive(token, path, **query):
    url = f"{API}/{path}?" + urllib.parse.urlencode({"supportsAllDrives": "true", **query})
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        body = json.loads(e.read() or b"{}")
        return e.code, body.get("error", {}).get("message", "")


def pick(c):
    """Google's desktop Picker flow, loopback redirect + PKCE."""
    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            got.update(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query))
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("Done. You can close this tab.".encode())

        def log_message(self, *a):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = f"http://127.0.0.1:{server.server_port}/"
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": c["client_id"], "redirect_uri": redirect, "response_type": "code",
        "scope": SCOPE, "access_type": "offline", "prompt": "consent",
        "trigger_onepick": "true", "allow_folder_selection": "true", "allow_multiple": "true",
        "code_challenge": challenge, "code_challenge_method": "S256",
    })
    print("Opening Google's consent screen and Picker in the browser…\n")
    webbrowser.open(url)
    t = threading.Thread(target=server.handle_request)
    t.start(); t.join()
    if "code" not in got:
        sys.exit(f"No grant: {got.get('error', ['cancelled'])[0]}")
    token = post("https://oauth2.googleapis.com/token", {
        "client_id": c["client_id"], "client_secret": c.get("client_secret", ""),
        "code": got["code"][0], "code_verifier": verifier,
        "grant_type": "authorization_code", "redirect_uri": redirect,
    })
    json.dump(token, open(TOKEN_FILE, "w"))
    os.chmod(TOKEN_FILE, 0o600)
    picked = [i for i in got.get("picked_file_ids", [""])[0].split(",") if i]
    return token["access_token"], picked


def saved_token(c):
    if not os.path.exists(TOKEN_FILE):
        sys.exit("No saved grant. Run `pick` first.")
    t = json.load(open(TOKEN_FILE))
    return post("https://oauth2.googleapis.com/token", {
        "client_id": c["client_id"], "client_secret": c.get("client_secret", ""),
        "refresh_token": t["refresh_token"], "grant_type": "refresh_token",
    })["access_token"]


def check(token, folder, probes):
    status, f = drive(token, f"files/{folder}", fields="id,name,mimeType")
    if status != 200:
        print(f"Folder {folder}: {status} {f}")
    else:
        print(f"Folder “{f['name']}”: the app can open it (picked).")
    status, page = drive(token, "files", q=f"'{folder}' in parents and trashed = false",
                         fields="files(id,name)", pageSize="1000")
    names = [x["name"] for x in page.get("files", [])] if status == 200 else []
    print(f"\nFiles in it that the app can see under drive.file: {len(names)}")
    for n in names:
        print(f"   · {n}")
    if probes:
        print("\nOpening files that are in the folder:")
    for p in probes:
        fid, _, label = p.partition("=")
        status, r = drive(token, f"files/{fid}", fields="id,name")
        shown = f"“{r['name']}”" if status == 200 else f"{status} {r}"
        print(f"   {label or fid}: {shown}")


def main():
    if len(sys.argv) < 3 or sys.argv[2] not in ("pick", "check"):
        sys.exit(__doc__)
    c = client(sys.argv[1])
    if sys.argv[2] == "pick":
        token, picked = pick(c)
        print(f"Picked {len(picked)} item(s).\n")
        for fid in picked:
            status, f = drive(token, f"files/{fid}", fields="id,name,mimeType")
            if status == 200 and f["mimeType"] == "application/vnd.google-apps.folder":
                check(token, fid, [])
                print()
            elif status == 200:
                print(f"   picked file “{f['name']}”")
    else:
        if len(sys.argv) < 4:
            sys.exit(__doc__)
        check(saved_token(c), sys.argv[3], sys.argv[4:])


if __name__ == "__main__":
    main()
