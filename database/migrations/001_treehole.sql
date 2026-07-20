-- Tree-hole schema for CloudBase PostgreSQL.
-- Each statement is separated for CloudBase CLI, which accepts one statement per call.

CREATE SCHEMA IF NOT EXISTS private;

-- migrate:split
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;

-- migrate:split
CREATE TABLE IF NOT EXISTS private.treehole_admins (
	user_id text PRIMARY KEY,
	created_at timestamptz NOT NULL DEFAULT now()
);

-- migrate:split
REVOKE ALL ON private.treehole_admins FROM PUBLIC, anon, authenticated;

-- migrate:split
GRANT USAGE ON SCHEMA private TO service_role;

-- migrate:split
GRANT ALL ON private.treehole_admins TO service_role;

-- migrate:split
INSERT INTO private.treehole_admins (user_id)
VALUES ('2078779555711959041')
ON CONFLICT (user_id) DO NOTHING;

-- migrate:split
CREATE OR REPLACE FUNCTION public.is_treehole_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
	SELECT EXISTS (
		SELECT 1
		FROM private.treehole_admins AS admin
		WHERE admin.user_id = (SELECT auth.uid())
	);
$$;

-- migrate:split
REVOKE ALL ON FUNCTION public.is_treehole_admin() FROM PUBLIC;

-- migrate:split
GRANT EXECUTE ON FUNCTION public.is_treehole_admin() TO anon, authenticated, service_role;

-- migrate:split
CREATE OR REPLACE FUNCTION public.treehole_hash_recovery_code(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
	SELECT encode(
		sha256(
			convert_to(
				lower(regexp_replace(coalesce(p_code, ''), '[^0-9a-zA-Z]', '', 'g')),
				'UTF8'
			)
		),
		'hex'
	);
$$;

-- migrate:split
CREATE TABLE IF NOT EXISTS public.treehole_conversations (
	id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	visitor_id text NOT NULL DEFAULT auth.uid(),
	support_code text NOT NULL UNIQUE DEFAULT (
		'TH-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
	),
	nickname varchar(30),
	contact_email varchar(254),
	recovery_code_hash varchar(64) NOT NULL,
	status varchar(16) NOT NULL DEFAULT 'open',
	recovery_reset_at timestamptz,
	created_at timestamptz NOT NULL DEFAULT now(),
	updated_at timestamptz NOT NULL DEFAULT now(),
	CONSTRAINT treehole_one_conversation_per_visitor UNIQUE (visitor_id),
	CONSTRAINT treehole_nickname_length CHECK (
		nickname IS NULL OR char_length(btrim(nickname)) BETWEEN 1 AND 30
	),
	CONSTRAINT treehole_email_length CHECK (
		contact_email IS NULL OR char_length(contact_email) <= 254
	),
	CONSTRAINT treehole_recovery_hash_format CHECK (
		recovery_code_hash ~ '^[0-9a-f]{64}$'
	),
	CONSTRAINT treehole_status_value CHECK (status IN ('open', 'closed'))
);

-- migrate:split
CREATE TABLE IF NOT EXISTS public.treehole_messages (
	id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	conversation_id uuid NOT NULL
		REFERENCES public.treehole_conversations(id) ON DELETE CASCADE,
	sender_id text NOT NULL DEFAULT auth.uid(),
	sender_type varchar(16) NOT NULL,
	content text NOT NULL,
	created_at timestamptz NOT NULL DEFAULT now(),
	CONSTRAINT treehole_sender_type_value CHECK (sender_type IN ('visitor', 'owner')),
	CONSTRAINT treehole_message_content_length CHECK (
		char_length(btrim(content)) BETWEEN 1 AND 2000
	)
);

-- migrate:split
CREATE INDEX IF NOT EXISTS treehole_messages_conversation_created_idx
ON public.treehole_messages (conversation_id, created_at);

-- migrate:split
CREATE INDEX IF NOT EXISTS treehole_conversations_updated_idx
ON public.treehole_conversations (updated_at DESC);

-- migrate:split
CREATE OR REPLACE FUNCTION public.treehole_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
	NEW.updated_at := now();
	RETURN NEW;
END;
$$;

-- migrate:split
DROP TRIGGER IF EXISTS treehole_conversations_set_updated_at
ON public.treehole_conversations;

-- migrate:split
CREATE TRIGGER treehole_conversations_set_updated_at
BEFORE UPDATE ON public.treehole_conversations
FOR EACH ROW
EXECUTE FUNCTION public.treehole_set_updated_at();

-- migrate:split
CREATE OR REPLACE FUNCTION public.treehole_touch_conversation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
	UPDATE public.treehole_conversations
	SET updated_at = now()
	WHERE id = NEW.conversation_id;
	RETURN NEW;
END;
$$;

-- migrate:split
DROP TRIGGER IF EXISTS treehole_messages_touch_conversation
ON public.treehole_messages;

-- migrate:split
CREATE TRIGGER treehole_messages_touch_conversation
AFTER INSERT ON public.treehole_messages
FOR EACH ROW
EXECUTE FUNCTION public.treehole_touch_conversation();

-- migrate:split
REVOKE ALL ON public.treehole_conversations FROM anon, authenticated;

-- migrate:split
REVOKE ALL ON public.treehole_messages FROM anon, authenticated;

-- migrate:split
GRANT SELECT (
	id,
	visitor_id,
	support_code,
	nickname,
	contact_email,
	status,
	recovery_reset_at,
	created_at,
	updated_at
) ON public.treehole_conversations TO anon, authenticated;

-- migrate:split
GRANT UPDATE (nickname, contact_email)
ON public.treehole_conversations TO anon, authenticated;

-- migrate:split
GRANT SELECT ON public.treehole_messages TO anon, authenticated;

-- migrate:split
GRANT INSERT (conversation_id, sender_type, content)
ON public.treehole_messages TO anon, authenticated;

-- migrate:split
GRANT ALL ON public.treehole_conversations, public.treehole_messages TO service_role;

-- migrate:split
ALTER TABLE public.treehole_conversations ENABLE ROW LEVEL SECURITY;

-- migrate:split
ALTER TABLE public.treehole_messages ENABLE ROW LEVEL SECURITY;

-- migrate:split
DROP POLICY IF EXISTS treehole_conversations_insert
ON public.treehole_conversations;

-- migrate:split
DROP POLICY IF EXISTS treehole_conversations_select
ON public.treehole_conversations;

-- migrate:split
CREATE POLICY treehole_conversations_select
ON public.treehole_conversations
FOR SELECT TO anon, authenticated
USING (
	visitor_id = (SELECT auth.uid())
	OR public.is_treehole_admin()
);

-- migrate:split
DROP POLICY IF EXISTS treehole_conversations_update
ON public.treehole_conversations;

-- migrate:split
CREATE POLICY treehole_conversations_update
ON public.treehole_conversations
FOR UPDATE TO anon, authenticated
USING (
	visitor_id = (SELECT auth.uid())
	OR public.is_treehole_admin()
)
WITH CHECK (
	visitor_id = (SELECT auth.uid())
	OR public.is_treehole_admin()
);

-- migrate:split
DROP POLICY IF EXISTS treehole_messages_select
ON public.treehole_messages;

-- migrate:split
CREATE POLICY treehole_messages_select
ON public.treehole_messages
FOR SELECT TO anon, authenticated
USING (
	public.is_treehole_admin()
	OR EXISTS (
		SELECT 1
		FROM public.treehole_conversations AS conversation
		WHERE conversation.id = treehole_messages.conversation_id
			AND conversation.visitor_id = (SELECT auth.uid())
	)
);

-- migrate:split
DROP POLICY IF EXISTS treehole_messages_insert
ON public.treehole_messages;

-- migrate:split
CREATE POLICY treehole_messages_insert
ON public.treehole_messages
FOR INSERT TO anon, authenticated
WITH CHECK (
	sender_id = (SELECT auth.uid())
	AND (
		(
			sender_type = 'visitor'
			AND EXISTS (
				SELECT 1
				FROM public.treehole_conversations AS conversation
				WHERE conversation.id = treehole_messages.conversation_id
					AND conversation.visitor_id = (SELECT auth.uid())
			)
		)
		OR (
			sender_type = 'owner'
			AND public.is_treehole_admin()
		)
	)
);

-- migrate:split
CREATE OR REPLACE FUNCTION public.rpc_create_treehole(
	p_nickname text DEFAULT NULL,
	p_contact_email text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
	current_user_id text;
	new_recovery_code text;
	new_conversation_id uuid;
	new_support_code text;
BEGIN
	current_user_id := auth.uid();
	IF current_user_id IS NULL THEN
		RAISE EXCEPTION 'Authentication required';
	END IF;

	IF EXISTS (
		SELECT 1 FROM public.treehole_conversations
		WHERE visitor_id = current_user_id
	) THEN
		RAISE EXCEPTION 'Current identity already has a treehole';
	END IF;

	new_recovery_code := upper(replace(gen_random_uuid()::text, '-', ''));

	INSERT INTO public.treehole_conversations (
		visitor_id,
		nickname,
		contact_email,
		recovery_code_hash
	)
	VALUES (
		current_user_id,
		nullif(btrim(p_nickname), ''),
		nullif(btrim(p_contact_email), ''),
		public.treehole_hash_recovery_code(new_recovery_code)
	)
	RETURNING id, support_code
	INTO new_conversation_id, new_support_code;

	RETURN jsonb_build_object(
		'conversation_id', new_conversation_id,
		'support_code', new_support_code,
		'recovery_code', new_recovery_code
	);
END;
$$;

-- migrate:split
CREATE OR REPLACE FUNCTION public.rpc_recover_treehole(
	p_support_code text,
	p_recovery_code text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
	current_user_id text;
	recovered_conversation_id uuid;
BEGIN
	current_user_id := auth.uid();
	IF current_user_id IS NULL THEN
		RAISE EXCEPTION 'Authentication required';
	END IF;

	IF EXISTS (
		SELECT 1 FROM public.treehole_conversations
		WHERE visitor_id = current_user_id
	) THEN
		RAISE EXCEPTION 'Current identity already has a treehole';
	END IF;

	UPDATE public.treehole_conversations
	SET visitor_id = current_user_id
	WHERE upper(support_code) = upper(btrim(p_support_code))
		AND recovery_code_hash = public.treehole_hash_recovery_code(p_recovery_code)
	RETURNING id INTO recovered_conversation_id;

	IF recovered_conversation_id IS NULL THEN
		RAISE EXCEPTION 'Invalid treehole code or recovery code';
	END IF;

	RETURN recovered_conversation_id;
END;
$$;

-- migrate:split
CREATE OR REPLACE FUNCTION public.rpc_admin_reset_treehole_recovery(
	p_conversation_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
	new_recovery_code text;
BEGIN
	IF NOT public.is_treehole_admin() THEN
		RAISE EXCEPTION 'Permission denied';
	END IF;

	new_recovery_code := upper(replace(gen_random_uuid()::text, '-', ''));

	UPDATE public.treehole_conversations
	SET
		recovery_code_hash = public.treehole_hash_recovery_code(new_recovery_code),
		recovery_reset_at = now()
	WHERE id = p_conversation_id;

	IF NOT FOUND THEN
		RAISE EXCEPTION 'Treehole not found';
	END IF;

	RETURN new_recovery_code;
END;
$$;

-- migrate:split
REVOKE ALL ON FUNCTION public.rpc_create_treehole(text, text) FROM PUBLIC;

-- migrate:split
REVOKE ALL ON FUNCTION public.rpc_recover_treehole(text, text) FROM PUBLIC;

-- migrate:split
REVOKE ALL ON FUNCTION public.rpc_admin_reset_treehole_recovery(uuid) FROM PUBLIC;

-- migrate:split
GRANT EXECUTE ON FUNCTION public.rpc_create_treehole(text, text)
TO anon, authenticated, service_role;

-- migrate:split
GRANT EXECUTE ON FUNCTION public.rpc_recover_treehole(text, text)
TO anon, authenticated, service_role;

-- migrate:split
GRANT EXECUTE ON FUNCTION public.rpc_admin_reset_treehole_recovery(uuid)
TO authenticated, service_role;
