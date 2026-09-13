# Tracktrans

Tracktrans is a vanilla HTML/CSS/JavaScript bookkeeping prototype with optional Supabase Auth and database integration.

## Local fallback

Open `index.html` through the existing Python server:

```bash
python3 -m http.server 8000
```

Without Supabase configuration, the app uses its existing localStorage MVP. This mode is useful for local UI testing only and is not production security.

## Supabase setup

1. Create a Supabase project.
2. Run [`supabase/schema.sql`](supabase/schema.sql) in the Supabase SQL Editor.
3. Enable Email/Password in Supabase Authentication.
4. Configure the browser with the public project URL and anon key before `index.html` loads:

```html
<script>
	window.TRACKTRANS_SUPABASE_CONFIG = {
		url: "https://YOUR_PROJECT.supabase.co",
		anonKey: "YOUR_PUBLIC_ANON_KEY"
	};
</script>
```

Only the public anon key belongs in browser configuration. Never expose a Supabase `service_role` key in `index.html` or any frontend asset.

When configured, login/register/logout use Supabase Auth and the client hydrates the active profile and business memberships through RLS-protected queries. Business creation, transaction reads/upsert/delete, invitation creation/acceptance, edit requests/approval, attendance reads, private photo upload, check-in, check-out, and audit writes use Supabase RPC/table/Storage paths. Staff management uses invitation and `business_members` in production mode. Reports and export render the currently loaded authorized data in the existing UI.

## Database model

The schema defines:

- `profiles`
- `businesses`
- `business_members`
- `invitations`
- `transactions`
- `transaction_edit_requests`
- `attendance`
- `audit_logs`
- private `attendance` Storage bucket policies

RLS policies enforce owner access, active staff membership, staff-owned transaction visibility, edit-request ownership, attendance ownership, and business scoping at the database layer.

## Security limitations

Supabase Auth/RLS is the production direction. The app still contains an explicit localStorage fallback for offline/local MVP mode and legacy-data migration; it must be disabled in a production deployment by requiring Supabase configuration. Invitation raw tokens are generated in the browser and only their SHA-256 hash is sent to the RPC; for higher assurance, token generation/delivery should be moved to an Edge Function. Never put a service role key in frontend code.
