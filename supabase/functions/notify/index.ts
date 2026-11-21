// Supabase Edge Function: content-free push for new MLS envelopes.
// Trigger: Database Webhook on INSERT into public.mls_messages -> POST here.
// Secrets: FCM_SERVICE_ACCOUNT (Firebase service account JSON), WEBHOOK_SECRET.
// Sends the same generic text as functions/lib.js: no sender, no conversation, no content.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const GENERIC = { title: 'Chatminusis', body: 'Nova mensagem' };

function b64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function accessToken(sa: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey(
    'pkcs8', Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(sig)}`,
    }),
  });
  return (await res.json()).access_token;
}

Deno.serve(async (req) => {
  if (req.headers.get('x-webhook-secret') !== Deno.env.get('WEBHOOK_SECRET')) return new Response('forbidden', { status: 403 });
  const { record } = await req.json();
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (!record || record.kind !== 'app') return new Response('ignored');
  const { data: members } = await db.from('conversation_members').select('user_id').eq('conversation_id', record.conversation_id);
  const recipients = (members ?? []).map((m) => m.user_id).filter((u) => u !== record.sender);
  if (recipients.length === 0) return new Response('no recipients');
  const { data: tokens } = await db.from('push_tokens').select('user_id, device_id, token').in('user_id', recipients);
  if (!tokens?.length) return new Response('no tokens');

  await sendAll(tokens, GENERIC, 'chatminusis', db);
  return new Response('ok');
});

type PushToken = { user_id: string; device_id: string; token: string };

async function sendAll(tokens: PushToken[], notification: { title: string; body: string }, tag: string, db: ReturnType<typeof createClient>) {
  const sa = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT')!);
  const bearer = await accessToken(sa);
  const url = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  await Promise.all(tokens.map(async (t) => {
    const res = await fetch(url, {
      method: 'POST',
      headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
      body: JSON.stringify({ message: {
        token: t.token, notification,
        android: { priority: 'high', notification: { tag } },
        apns: { headers: { 'apns-collapse-id': tag }, payload: { aps: { sound: 'default' } } },
      } }),
    });
    if (res.status === 404 || res.status === 400) {
      await db.from('push_tokens').delete().eq('user_id', t.user_id).eq('device_id', t.device_id);
    }
  }));
}
