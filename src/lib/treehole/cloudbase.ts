import Cloudbase from "@cloudbase/js-sdk";

const TREEHOLE_ENV_ID =
	import.meta.env.PUBLIC_CLOUDBASE_ENV_ID || "myblog-d7g9jscvec2c9af0d";

export const TREEHOLE_OWNER_UID = "2078779555711959041";

export interface TreeholeConversation {
	id: string;
	visitor_id: string;
	support_code: string;
	nickname: string | null;
	contact_email: string | null;
	status: "open" | "closed";
	recovery_reset_at: string | null;
	created_at: string;
	updated_at: string;
}

export interface TreeholeMessage {
	id: string;
	conversation_id: string;
	sender_id: string;
	sender_type: "visitor" | "owner";
	content: string;
	created_at: string;
}

export interface RecoveryDetails {
	conversation_id: string;
	support_code: string;
	recovery_code: string;
}

type CloudBaseError = {
	code?: string;
	details?: string;
	message?: string;
};

type CloudBaseResult<T> = {
	data: T | null;
	error: CloudBaseError | null;
};

interface TreeholeQuery extends PromiseLike<CloudBaseResult<unknown>> {
	eq(column: string, value: string): TreeholeQuery;
	insert(values: Record<string, unknown>): TreeholeQuery;
	limit(value: number): TreeholeQuery;
	order(column: string, options: { ascending: boolean }): TreeholeQuery;
	select(columns: string): TreeholeQuery;
	update(values: Record<string, unknown>): TreeholeQuery;
}

interface TreeholeRdbClient {
	from(relation: string): TreeholeQuery;
	rpc(name: string, args: Record<string, unknown>): TreeholeQuery;
}

const app = Cloudbase.init({ env: TREEHOLE_ENV_ID });
const auth = app.auth();
const db = (app.rdb as unknown as () => TreeholeRdbClient).call(app);

function getErrorMessage(error: unknown): string {
	if (typeof error === "string") return error;
	if (error && typeof error === "object") {
		const candidate = error as CloudBaseError;
		return candidate.message || candidate.details || "请求失败，请稍后重试";
	}
	return "请求失败，请稍后重试";
}

function unwrap<T>(result: CloudBaseResult<T>): T {
	if (result.error) throw new Error(getErrorMessage(result.error));
	return result.data as T;
}

async function getCurrentUid(): Promise<string | null> {
	const user = await auth.getCurrentUser();
	return user?.uid || null;
}

export async function ensureVisitorIdentity(): Promise<string> {
	let uid = await getCurrentUid();
	if (uid === TREEHOLE_OWNER_UID) {
		await auth.signOut();
		uid = null;
	}

	if (!uid) {
		const result = (await auth.signInAnonymously()) as CloudBaseResult<unknown>;
		if (result?.error) throw new Error(getErrorMessage(result.error));
		uid = await getCurrentUid();
	}

	if (!uid) throw new Error("无法建立匿名身份，请刷新页面后重试");
	return uid;
}

export async function prepareAdminSession(): Promise<boolean> {
	const uid = await getCurrentUid();
	if (uid === TREEHOLE_OWNER_UID) return true;
	if (uid) await auth.signOut();
	return false;
}

export async function signInAsAdmin(
	username: string,
	password: string,
): Promise<void> {
	if (await getCurrentUid()) await auth.signOut();

	const result = (await auth.signInWithPassword({
		username,
		password,
	})) as CloudBaseResult<unknown>;
	if (result?.error) throw new Error(getErrorMessage(result.error));

	if ((await getCurrentUid()) !== TREEHOLE_OWNER_UID) {
		await auth.signOut();
		throw new Error("这个账号没有树洞管理权限");
	}
}

export async function signOut(): Promise<void> {
	await auth.signOut();
}

const conversationColumns =
	"id,visitor_id,support_code,nickname,contact_email,status,recovery_reset_at,created_at,updated_at";

export async function getVisitorConversation(): Promise<TreeholeConversation | null> {
	const result = (await db
		.from("treehole_conversations")
		.select(conversationColumns)
		.limit(1)) as CloudBaseResult<TreeholeConversation[]>;
	const conversations = unwrap(result) || [];
	return conversations[0] || null;
}

export async function listConversations(): Promise<TreeholeConversation[]> {
	const result = (await db
		.from("treehole_conversations")
		.select(conversationColumns)
		.order("updated_at", { ascending: false })
		.limit(200)) as CloudBaseResult<TreeholeConversation[]>;
	return unwrap(result) || [];
}

export async function listMessages(
	conversationId: string,
): Promise<TreeholeMessage[]> {
	const result = (await db
		.from("treehole_messages")
		.select("id,conversation_id,sender_id,sender_type,content,created_at")
		.eq("conversation_id", conversationId)
		.order("created_at", { ascending: true })
		.limit(500)) as CloudBaseResult<TreeholeMessage[]>;
	return unwrap(result) || [];
}

export async function createTreehole(
	nickname: string,
	contactEmail: string,
): Promise<RecoveryDetails> {
	const result = (await db.rpc("rpc_create_treehole", {
		p_nickname: nickname.trim() || null,
		p_contact_email: contactEmail.trim() || null,
	})) as CloudBaseResult<RecoveryDetails>;
	return unwrap(result);
}

export async function recoverTreehole(
	supportCode: string,
	recoveryCode: string,
): Promise<string> {
	const result = (await db.rpc("rpc_recover_treehole", {
		p_support_code: supportCode.trim(),
		p_recovery_code: recoveryCode.trim(),
	})) as CloudBaseResult<string>;
	return unwrap(result);
}

export async function updateVisitorProfile(
	conversationId: string,
	nickname: string,
	contactEmail: string,
): Promise<void> {
	const result = (await db
		.from("treehole_conversations")
		.update({
			nickname: nickname.trim() || null,
			contact_email: contactEmail.trim() || null,
		})
		.eq("id", conversationId)) as CloudBaseResult<unknown>;
	unwrap(result);
}

export async function sendMessage(
	conversationId: string,
	senderType: "visitor" | "owner",
	content: string,
): Promise<void> {
	const result = (await db.from("treehole_messages").insert({
		conversation_id: conversationId,
		sender_type: senderType,
		content: content.trim(),
	})) as CloudBaseResult<unknown>;
	unwrap(result);
}

export async function resetRecoveryCode(
	conversationId: string,
): Promise<string> {
	const result = (await db.rpc("rpc_admin_reset_treehole_recovery", {
		p_conversation_id: conversationId,
	})) as CloudBaseResult<string>;
	return unwrap(result);
}
