# Outbound email (SMTP)

Forge sends email for customer-portal magic links and notifications. Unlike
most settings, SMTP is **not** configured through environment variables — it
lives in Forge's runtime settings (Admin → **Integrations**), is stored in the
database, and takes effect immediately without a restart. Passwords are
encrypted at rest via ASP.NET Data Protection.

## Settings

| Key | Default | Notes |
|---|---|---|
| Mode | `Mock` | `Mock` logs outbound email to the integration outbox without sending — the safe default for dev/demo. Set `Real` to actually send. `Disabled` turns email off entirely. |
| Host | *(empty)* | SMTP server hostname or IP |
| Port | `587` | 587 STARTTLS, 465 SSL, 25 plain (internal relays) |
| Use SSL/TLS | `true` | Set `false` for plain port-25 relays |
| Username | *(empty)* | Empty = unauthenticated (e.g. an internal relay) |
| Password | *(empty)* | Stored encrypted |
| From Address | *(empty)* | Sender shown on outbound email |
| From Name | *(empty)* | |

Nothing sends while Mode is `Mock` — if email "doesn't work," check the mode
first, then the integration outbox for what would have been sent.

## Examples

**Google Workspace SMTP relay** — authenticate with an app password (requires
2-step verification), and note Google rejects sender domains that aren't
registered to your Workspace, so From Address must use a Workspace domain:

```
Mode: Real    Host: smtp-relay.gmail.com    Port: 587    Use SSL: true
Username: you@yourdomain.com    Password: <16-char app password>
From Address: noreply@yourdomain.com
```

**Internal LAN relay** (postfix or similar, no auth):

```
Mode: Real    Host: mail.internal.example    Port: 25    Use SSL: false
From Address: noreply@yourdomain.com
```

**SendGrid / Mailgun / etc.**: the provider's SMTP host with the API key as
the password, per their docs.
