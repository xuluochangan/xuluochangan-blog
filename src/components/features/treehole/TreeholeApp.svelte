<script lang="ts">
import { onMount, tick } from "svelte";
import {
	createTreehole,
	ensureVisitorIdentity,
	getVisitorConversation,
	listConversations,
	listMessages,
	prepareAdminSession,
	type RecoveryDetails,
	recoverTreehole,
	resetRecoveryCode,
	sendMessage,
	signInAsAdmin,
	signOut,
	type TreeholeConversation,
	type TreeholeMessage,
	updateVisitorProfile,
} from "../../../lib/treehole/cloudbase";

type Screen = "loading" | "welcome" | "conversation" | "admin-login" | "admin";
type WelcomeTab = "create" | "recover";

let screen: Screen = "loading";
let welcomeTab: WelcomeTab = "create";
let busy = false;
let errorMessage = "";
let noticeMessage = "";
let pollTimer: number | undefined;
let messageListElement: HTMLDivElement | undefined;

let conversation: TreeholeConversation | null = null;
let messages: TreeholeMessage[] = [];
let nickname = "";
let contactEmail = "";
let supportCode = "";
let recoveryCode = "";
let draftMessage = "";
let editingProfile = false;

let adminUsername = "";
let adminPassword = "";
let conversations: TreeholeConversation[] = [];
let selectedConversation: TreeholeConversation | null = null;
let adminDraftMessage = "";
let recoveryDetails: RecoveryDetails | null = null;
let recoveryDialogTitle = "请保存恢复信息";

function friendlyError(error: unknown): string {
	const message = error instanceof Error ? error.message : String(error);
	if (message.includes("already has a treehole")) {
		return "当前身份已经有一个树洞，请刷新页面查看。";
	}
	if (message.includes("Invalid treehole code")) {
		return "树洞编号或恢复码不正确，请检查后重试。";
	}
	if (message.includes("Invalid login credentials")) {
		return "用户名或密码不正确。";
	}
	if (message.includes("security") || message.includes("domain")) {
		return "当前域名尚未加入 CloudBase 安全来源，请联系站长。";
	}
	return message || "请求失败，请稍后重试。";
}

function clearFeedback(): void {
	errorMessage = "";
	noticeMessage = "";
}

function formatDate(value: string): string {
	return new Intl.DateTimeFormat("zh-CN", {
		month: "2-digit",
		day: "2-digit",
		hour: "2-digit",
		minute: "2-digit",
	}).format(new Date(value));
}

function displayName(item: TreeholeConversation): string {
	return item.nickname?.trim() || "匿名访客";
}

async function scrollMessagesToBottom(): Promise<void> {
	await tick();
	if (messageListElement) {
		messageListElement.scrollTop = messageListElement.scrollHeight;
	}
}

function startPolling(mode: "visitor" | "admin"): void {
	if (pollTimer) window.clearInterval(pollTimer);
	pollTimer = window.setInterval(async () => {
		if (!conversation && !selectedConversation) return;
		try {
			if (mode === "visitor" && conversation) {
				messages = await listMessages(conversation.id);
			} else if (mode === "admin" && selectedConversation) {
				messages = await listMessages(selectedConversation.id);
				await refreshAdminList(true);
			}
		} catch {
			// 轮询失败时保留当前内容，下一轮自动重试。
		}
	}, 10_000);
}

async function openVisitorConversation(
	item: TreeholeConversation,
): Promise<void> {
	conversation = item;
	nickname = item.nickname || "";
	contactEmail = item.contact_email || "";
	messages = await listMessages(item.id);
	screen = "conversation";
	startPolling("visitor");
	await scrollMessagesToBottom();
}

async function initializeVisitor(): Promise<void> {
	await ensureVisitorIdentity();
	const item = await getVisitorConversation();
	if (item) await openVisitorConversation(item);
	else screen = "welcome";
}

async function initializeAdmin(): Promise<void> {
	if (await prepareAdminSession()) {
		screen = "admin";
		await refreshAdminList(false);
	} else {
		screen = "admin-login";
	}
}

onMount(() => {
	const adminMode =
		new URLSearchParams(window.location.search).get("admin") === "1";
	(adminMode ? initializeAdmin() : initializeVisitor()).catch((error) => {
		errorMessage = friendlyError(error);
		screen = adminMode ? "admin-login" : "welcome";
	});

	return () => {
		if (pollTimer) window.clearInterval(pollTimer);
	};
});

async function handleCreate(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	clearFeedback();
	busy = true;
	try {
		const details = await createTreehole(nickname, contactEmail);
		recoveryDetails = details;
		recoveryDialogTitle = "树洞创建成功，请保存恢复信息";
		const item = await getVisitorConversation();
		if (!item) throw new Error("树洞已创建，但暂时无法读取，请刷新页面");
		await openVisitorConversation(item);
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleRecover(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	clearFeedback();
	busy = true;
	try {
		await recoverTreehole(supportCode, recoveryCode);
		const item = await getVisitorConversation();
		if (!item) throw new Error("恢复成功，但暂时无法读取树洞，请刷新页面");
		await openVisitorConversation(item);
		noticeMessage = "树洞已恢复到这台设备。";
		supportCode = "";
		recoveryCode = "";
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleSaveProfile(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	if (!conversation) return;
	clearFeedback();
	busy = true;
	try {
		await updateVisitorProfile(conversation.id, nickname, contactEmail);
		conversation = {
			...conversation,
			nickname: nickname.trim() || null,
			contact_email: contactEmail.trim() || null,
		};
		editingProfile = false;
		noticeMessage = "称呼和联系邮箱已更新。";
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleVisitorSend(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	if (!conversation || !draftMessage.trim()) return;
	clearFeedback();
	busy = true;
	try {
		await sendMessage(conversation.id, "visitor", draftMessage);
		draftMessage = "";
		messages = await listMessages(conversation.id);
		await scrollMessagesToBottom();
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleAdminLogin(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	clearFeedback();
	busy = true;
	try {
		await signInAsAdmin(adminUsername.trim(), adminPassword);
		adminPassword = "";
		screen = "admin";
		await refreshAdminList(false);
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function refreshAdminList(quiet: boolean): Promise<void> {
	try {
		const next = await listConversations();
		conversations = next;
		if (selectedConversation) {
			selectedConversation =
				next.find((item) => item.id === selectedConversation?.id) || null;
		}
	} catch (error) {
		if (!quiet) throw error;
	}
}

async function selectConversation(item: TreeholeConversation): Promise<void> {
	clearFeedback();
	selectedConversation = item;
	messages = [];
	busy = true;
	try {
		messages = await listMessages(item.id);
		startPolling("admin");
		await scrollMessagesToBottom();
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleAdminSend(event: SubmitEvent): Promise<void> {
	event.preventDefault();
	if (!selectedConversation || !adminDraftMessage.trim()) return;
	clearFeedback();
	busy = true;
	try {
		await sendMessage(selectedConversation.id, "owner", adminDraftMessage);
		adminDraftMessage = "";
		messages = await listMessages(selectedConversation.id);
		await refreshAdminList(true);
		await scrollMessagesToBottom();
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleResetRecovery(): Promise<void> {
	if (!selectedConversation) return;
	if (!window.confirm("重置后，旧恢复码会立即失效。确定继续吗？")) return;
	clearFeedback();
	busy = true;
	try {
		const code = await resetRecoveryCode(selectedConversation.id);
		recoveryDetails = {
			conversation_id: selectedConversation.id,
			support_code: selectedConversation.support_code,
			recovery_code: code,
		};
		recoveryDialogTitle = "恢复码已重置，请转交给访客";
	} catch (error) {
		errorMessage = friendlyError(error);
	} finally {
		busy = false;
	}
}

async function handleAdminSignOut(): Promise<void> {
	if (pollTimer) window.clearInterval(pollTimer);
	await signOut();
	selectedConversation = null;
	conversations = [];
	messages = [];
	screen = "admin-login";
}

function recoveryText(): string {
	if (!recoveryDetails) return "";
	return `树洞编号：${recoveryDetails.support_code}\n恢复码：${recoveryDetails.recovery_code}\n博客：https://www.xuluochangan.com/treehole/`;
}

async function copyRecoveryDetails(): Promise<void> {
	try {
		await navigator.clipboard.writeText(recoveryText());
		noticeMessage = "恢复信息已复制。";
	} catch {
		errorMessage = "浏览器未允许自动复制，请手动选中并复制恢复信息。";
	}
}

function downloadRecoveryDetails(): void {
	const blob = new Blob([recoveryText()], { type: "text/plain;charset=utf-8" });
	const url = URL.createObjectURL(blob);
	const link = document.createElement("a");
	link.href = url;
	link.download = `树洞恢复信息-${recoveryDetails?.support_code || ""}.txt`;
	link.click();
	URL.revokeObjectURL(url);
}
</script>

<div class="treehole-app">
	{#if errorMessage}
		<div class="feedback error" role="alert">{errorMessage}</div>
	{/if}
	{#if noticeMessage}
		<div class="feedback notice" role="status">{noticeMessage}</div>
	{/if}

	{#if screen === "loading"}
		<div class="loading-state" aria-live="polite">
			<span class="spinner"></span>
			<p>正在打开你的树洞……</p>
		</div>
	{:else if screen === "welcome"}
		<section class="welcome-panel">
			<div class="privacy-note">
				<strong>这里只有你和我能看见。</strong>
				<span>无需注册，系统会为这台浏览器生成匿名身份。邮箱仅用于你自愿留下联系方式，不会验证。</span>
			</div>

			<div class="tabs" role="tablist" aria-label="树洞操作">
				<button class:active={welcomeTab === "create"} type="button" onclick={() => (welcomeTab = "create")}>新建树洞</button>
				<button class:active={welcomeTab === "recover"} type="button" onclick={() => (welcomeTab = "recover")}>恢复已有树洞</button>
			</div>

			{#if welcomeTab === "create"}
				<form class="form-stack" onsubmit={handleCreate}>
					<label>
						<span>怎么称呼你（选填）</span>
						<input bind:value={nickname} maxlength="30" placeholder="留空即为匿名访客" autocomplete="nickname" />
					</label>
					<label>
						<span>联系邮箱（选填）</span>
						<input bind:value={contactEmail} maxlength="254" type="email" placeholder="不会发送验证码" autocomplete="email" />
					</label>
					<button class="primary-button" type="submit" disabled={busy}>{busy ? "正在创建……" : "创建我的树洞"}</button>
					<p class="form-hint">创建后请立即保存树洞编号和恢复码。清除浏览器数据或更换设备时，需要它们找回对话。</p>
				</form>
			{:else}
				<form class="form-stack" onsubmit={handleRecover}>
					<label>
						<span>树洞编号</span>
						<input bind:value={supportCode} required placeholder="例如 TH-12AB34CD56EF" autocomplete="off" />
					</label>
					<label>
						<span>恢复码</span>
						<input bind:value={recoveryCode} required placeholder="输入创建时保存的恢复码" autocomplete="off" />
					</label>
					<button class="primary-button" type="submit" disabled={busy}>{busy ? "正在恢复……" : "恢复到这台设备"}</button>
					<p class="form-hint">如果恢复码遗失，可以告诉我你的称呼和树洞编号，由我核对后为你重置。</p>
				</form>
			{/if}
			<button class="admin-entry" type="button" onclick={() => (window.location.href = "/treehole/?admin=1")}>站长入口</button>
		</section>
	{:else if screen === "conversation" && conversation}
		<section class="conversation-panel">
			<header class="conversation-header">
				<div>
					<p class="eyebrow">你的私人树洞</p>
					<h2>{displayName(conversation)}</h2>
					<p class="support-code">树洞编号：<strong>{conversation.support_code}</strong></p>
				</div>
				<button class="secondary-button" type="button" onclick={() => (editingProfile = !editingProfile)}>{editingProfile ? "收起" : "修改称呼"}</button>
			</header>

			{#if editingProfile}
				<form class="profile-form" onsubmit={handleSaveProfile}>
					<label><span>称呼</span><input bind:value={nickname} maxlength="30" placeholder="匿名访客" /></label>
					<label><span>联系邮箱</span><input bind:value={contactEmail} maxlength="254" type="email" placeholder="选填，不验证" /></label>
					<button class="primary-button compact" type="submit" disabled={busy}>保存</button>
				</form>
			{/if}

			<div class="messages" bind:this={messageListElement} aria-live="polite">
				{#if messages.length === 0}
					<div class="empty-messages">
						<p>这里还没有留言。</p>
						<span>写下你想说的话吧，我看到后会在这里回复。</span>
					</div>
				{:else}
					{#each messages as message (message.id)}
						<article class:mine={message.sender_type === "visitor"} class="message-row">
							<div class="message-meta"><span>{message.sender_type === "visitor" ? "你" : "许洛长安"}</span><time>{formatDate(message.created_at)}</time></div>
							<p>{message.content}</p>
						</article>
					{/each}
				{/if}
			</div>

			<form class="composer" onsubmit={handleVisitorSend}>
				<label class="sr-only" for="visitor-message">留言内容</label>
				<textarea id="visitor-message" bind:value={draftMessage} maxlength="2000" required rows="4" placeholder="写下想对我说的话……"></textarea>
				<div class="composer-footer"><span>{draftMessage.length}/2000</span><button class="primary-button compact" type="submit" disabled={busy || !draftMessage.trim()}>{busy ? "发送中……" : "发送留言"}</button></div>
			</form>
		</section>
	{:else if screen === "admin-login"}
		<section class="admin-login-panel">
			<p class="eyebrow">树洞管理</p>
			<h2>站长登录</h2>
			<p>使用 CloudBase 的站长用户名和密码登录。</p>
			<form class="form-stack" onsubmit={handleAdminLogin}>
				<label><span>用户名</span><input bind:value={adminUsername} required autocomplete="username" /></label>
				<label><span>密码</span><input bind:value={adminPassword} required type="password" autocomplete="current-password" /></label>
				<button class="primary-button" type="submit" disabled={busy}>{busy ? "正在登录……" : "登录管理端"}</button>
			</form>
			<button class="admin-entry" type="button" onclick={() => (window.location.href = "/treehole/")}>返回访客入口</button>
		</section>
	{:else if screen === "admin"}
		<section class="admin-panel">
			<header class="admin-toolbar">
				<div><p class="eyebrow">树洞管理</p><h2>私人留言</h2></div>
				<div class="toolbar-actions"><button class="secondary-button" type="button" onclick={() => refreshAdminList(false)}>刷新</button><button class="secondary-button" type="button" onclick={handleAdminSignOut}>退出</button></div>
			</header>

			<div class="admin-grid">
				<aside class="conversation-list" aria-label="树洞列表">
					{#if conversations.length === 0}
						<p class="list-empty">暂时还没有访客留言。</p>
					{:else}
						{#each conversations as item (item.id)}
							<button class:selected={selectedConversation?.id === item.id} type="button" onclick={() => selectConversation(item)}>
								<span class="list-title">{displayName(item)}</span>
								<span class="list-code">{item.support_code}</span>
								<time>{formatDate(item.updated_at)}</time>
							</button>
						{/each}
					{/if}
				</aside>

				<div class="admin-conversation">
					{#if selectedConversation}
						<header class="selected-header">
							<div><h3>{displayName(selectedConversation)}</h3><p>{selectedConversation.support_code}{selectedConversation.contact_email ? ` · ${selectedConversation.contact_email}` : ""}</p></div>
							<button class="secondary-button" type="button" onclick={handleResetRecovery} disabled={busy}>重置恢复码</button>
						</header>
						<div class="messages admin-messages" bind:this={messageListElement} aria-live="polite">
							{#if messages.length === 0}<div class="empty-messages"><p>还没有留言。</p></div>{/if}
							{#each messages as message (message.id)}
								<article class:mine={message.sender_type === "owner"} class="message-row">
									<div class="message-meta"><span>{message.sender_type === "owner" ? "我" : displayName(selectedConversation)}</span><time>{formatDate(message.created_at)}</time></div>
									<p>{message.content}</p>
								</article>
							{/each}
						</div>
						<form class="composer" onsubmit={handleAdminSend}>
							<textarea bind:value={adminDraftMessage} maxlength="2000" required rows="3" aria-label="回复内容" placeholder="回复这位访客……"></textarea>
							<div class="composer-footer"><span>{adminDraftMessage.length}/2000</span><button class="primary-button compact" type="submit" disabled={busy || !adminDraftMessage.trim()}>发送回复</button></div>
						</form>
					{:else}
						<div class="select-prompt">从左侧选择一个树洞查看对话。</div>
					{/if}
				</div>
			</div>
		</section>
	{/if}
</div>

{#if recoveryDetails}
	<div class="dialog-backdrop" role="presentation">
		<section class="recovery-dialog" role="dialog" aria-modal="true" aria-labelledby="recovery-title">
			<p class="eyebrow">重要信息</p>
			<h2 id="recovery-title">{recoveryDialogTitle}</h2>
			<p class="dialog-description">恢复码不会以明文保存在数据库里，关闭后无法再次查看；站长只能为你生成新的恢复码。</p>
			<div class="recovery-values">
				<label><span>树洞编号</span><code>{recoveryDetails.support_code}</code></label>
				<label><span>恢复码</span><code>{recoveryDetails.recovery_code}</code></label>
			</div>
			<div class="dialog-actions">
				<button class="secondary-button" type="button" onclick={copyRecoveryDetails}>复制</button>
				<button class="secondary-button" type="button" onclick={downloadRecoveryDetails}>下载 TXT</button>
				<button class="primary-button compact" type="button" onclick={() => (recoveryDetails = null)}>我已保存</button>
			</div>
		</section>
	</div>
{/if}

<style>
	.treehole-app { color: var(--content); }
	.feedback { margin-bottom: 1rem; padding: .8rem 1rem; border-radius: .8rem; font-size: .9rem; }
	.feedback.error { color: #b42318; background: rgba(240, 68, 56, .1); border: 1px solid rgba(240, 68, 56, .2); }
	.feedback.notice { color: #067647; background: rgba(18, 183, 106, .1); border: 1px solid rgba(18, 183, 106, .2); }
	.loading-state { min-height: 22rem; display: grid; place-content: center; justify-items: center; gap: 1rem; color: var(--content-secondary); }
	.spinner { width: 2rem; height: 2rem; border: 3px solid rgba(127,127,127,.2); border-top-color: var(--primary); border-radius: 50%; animation: spin .8s linear infinite; }
	@keyframes spin { to { transform: rotate(360deg); } }
	.welcome-panel, .admin-login-panel { max-width: 38rem; margin: 0 auto; padding: 1rem 0; }
	.privacy-note { display: flex; flex-direction: column; gap: .35rem; padding: 1rem 1.1rem; margin-bottom: 1.5rem; border-radius: 1rem; background: color-mix(in srgb, var(--primary) 10%, transparent); border: 1px solid color-mix(in srgb, var(--primary) 24%, transparent); }
	.privacy-note span, .form-hint, .admin-login-panel > p { color: var(--content-secondary); font-size: .9rem; line-height: 1.7; }
	.tabs { display: grid; grid-template-columns: 1fr 1fr; gap: .5rem; margin-bottom: 1.25rem; padding: .3rem; border-radius: .9rem; background: var(--btn-regular-bg); }
	.tabs button { padding: .7rem; border-radius: .7rem; color: var(--content-secondary); transition: .2s; }
	.tabs button.active { color: white; background: var(--primary); box-shadow: 0 4px 12px color-mix(in srgb, var(--primary) 25%, transparent); }
	.form-stack { display: flex; flex-direction: column; gap: 1rem; }
	label { display: flex; flex-direction: column; gap: .45rem; }
	label > span { font-size: .86rem; font-weight: 600; color: var(--content-secondary); }
	input, textarea { width: 100%; color: var(--content); background: var(--card-bg); border: 1px solid var(--line-divider); border-radius: .8rem; padding: .75rem .9rem; outline: none; transition: border-color .2s, box-shadow .2s; }
	input:focus, textarea:focus { border-color: var(--primary); box-shadow: 0 0 0 3px color-mix(in srgb, var(--primary) 14%, transparent); }
	textarea { resize: vertical; line-height: 1.65; }
	.primary-button, .secondary-button { display: inline-flex; align-items: center; justify-content: center; border-radius: .8rem; font-weight: 600; transition: transform .15s, opacity .15s, background .15s; }
	.primary-button { min-height: 2.8rem; padding: .65rem 1.15rem; color: white; background: var(--primary); }
	.primary-button.compact { min-height: 2.4rem; padding: .5rem 1rem; }
	.secondary-button { min-height: 2.4rem; padding: .5rem .85rem; color: var(--content); background: var(--btn-regular-bg); border: 1px solid var(--line-divider); }
	.primary-button:hover:not(:disabled), .secondary-button:hover:not(:disabled) { transform: translateY(-1px); }
	button:disabled { opacity: .55; cursor: not-allowed; }
	.form-hint { margin: 0; }
	.admin-entry { display: block; margin: 2rem auto 0; color: var(--content-secondary); font-size: .8rem; text-decoration: underline; text-underline-offset: .2rem; }
	.conversation-panel { max-width: 52rem; margin: 0 auto; }
	.conversation-header, .admin-toolbar, .selected-header { display: flex; justify-content: space-between; align-items: center; gap: 1rem; }
	.eyebrow { margin: 0 0 .2rem; color: var(--primary); font-size: .78rem; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; }
	h2, h3 { margin: 0; color: var(--content); }
	.conversation-header h2, .admin-toolbar h2, .admin-login-panel h2 { font-size: 1.55rem; }
	.support-code, .selected-header p { margin: .35rem 0 0; color: var(--content-secondary); font-size: .85rem; }
	.profile-form { display: grid; grid-template-columns: 1fr 1.4fr auto; align-items: end; gap: .75rem; margin-top: 1rem; padding: 1rem; border-radius: 1rem; background: var(--btn-regular-bg); }
	.messages { min-height: 20rem; max-height: 32rem; overflow-y: auto; margin: 1.2rem 0 1rem; padding: 1rem; border-radius: 1rem; background: color-mix(in srgb, var(--card-bg) 70%, transparent); border: 1px solid var(--line-divider); }
	.empty-messages, .select-prompt { min-height: 16rem; display: grid; place-content: center; text-align: center; color: var(--content-secondary); }
	.empty-messages p { margin: 0 0 .35rem; font-weight: 600; color: var(--content); }
	.empty-messages span { font-size: .9rem; }
	.message-row { width: fit-content; max-width: min(84%, 36rem); margin: 0 0 .85rem; padding: .75rem .9rem; border-radius: .25rem 1rem 1rem 1rem; background: var(--btn-regular-bg); border: 1px solid var(--line-divider); }
	.message-row.mine { margin-left: auto; border-radius: 1rem .25rem 1rem 1rem; background: color-mix(in srgb, var(--primary) 14%, var(--card-bg)); border-color: color-mix(in srgb, var(--primary) 25%, transparent); }
	.message-meta { display: flex; align-items: center; gap: .7rem; margin-bottom: .3rem; color: var(--content-secondary); font-size: .72rem; }
	.message-meta span { font-weight: 700; color: var(--primary); }
	.message-row p { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; line-height: 1.65; }
	.composer { padding: .9rem; border-radius: 1rem; background: var(--btn-regular-bg); border: 1px solid var(--line-divider); }
	.composer textarea { background: var(--card-bg); }
	.composer-footer { display: flex; justify-content: space-between; align-items: center; gap: 1rem; margin-top: .65rem; }
	.composer-footer > span { color: var(--content-secondary); font-size: .75rem; }
	.admin-login-panel > h2 { margin-bottom: .4rem; }
	.admin-login-panel .form-stack { margin-top: 1.2rem; }
	.admin-toolbar { margin-bottom: 1rem; }
	.toolbar-actions { display: flex; gap: .5rem; }
	.admin-grid { display: grid; grid-template-columns: minmax(14rem, 18rem) 1fr; min-height: 34rem; border: 1px solid var(--line-divider); border-radius: 1rem; overflow: hidden; }
	.conversation-list { overflow-y: auto; max-height: 42rem; border-right: 1px solid var(--line-divider); background: color-mix(in srgb, var(--btn-regular-bg) 65%, transparent); }
	.conversation-list button { width: 100%; display: grid; grid-template-columns: 1fr auto; gap: .25rem .7rem; padding: .9rem; text-align: left; border-bottom: 1px solid var(--line-divider); transition: background .15s; }
	.conversation-list button:hover, .conversation-list button.selected { background: color-mix(in srgb, var(--primary) 12%, transparent); }
	.list-title { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	.list-code, .conversation-list time { color: var(--content-secondary); font-size: .72rem; }
	.conversation-list time { grid-row: 1; grid-column: 2; }
	.list-empty { padding: 1rem; color: var(--content-secondary); font-size: .9rem; }
	.admin-conversation { min-width: 0; padding: 1rem; }
	.selected-header h3 { font-size: 1.1rem; }
	.admin-messages { min-height: 20rem; max-height: 27rem; }
	.dialog-backdrop { position: fixed; inset: 0; z-index: 1000; display: grid; place-items: center; padding: 1rem; background: rgba(0,0,0,.55); backdrop-filter: blur(5px); }
	.recovery-dialog { width: min(34rem, 100%); padding: 1.4rem; border-radius: 1.1rem; color: var(--content); background: var(--card-bg); border: 1px solid var(--line-divider); box-shadow: 0 20px 60px rgba(0,0,0,.3); }
	.recovery-dialog h2 { font-size: 1.35rem; }
	.dialog-description { color: var(--content-secondary); font-size: .88rem; line-height: 1.65; }
	.recovery-values { display: grid; gap: .8rem; margin: 1rem 0; }
	.recovery-values label { padding: .8rem; border-radius: .8rem; background: var(--btn-regular-bg); }
	.recovery-values code { font-size: .95rem; overflow-wrap: anywhere; user-select: all; }
	.dialog-actions { display: flex; justify-content: flex-end; flex-wrap: wrap; gap: .55rem; }
	.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
	@media (max-width: 760px) {
		.profile-form { grid-template-columns: 1fr; }
		.admin-grid { grid-template-columns: 1fr; }
		.conversation-list { max-height: 13rem; border-right: 0; border-bottom: 1px solid var(--line-divider); }
		.admin-conversation { padding: .75rem; }
		.messages { padding: .7rem; }
		.message-row { max-width: 92%; }
	}
	@media (max-width: 480px) {
		.conversation-header, .selected-header { align-items: flex-start; flex-direction: column; }
		.selected-header .secondary-button { width: 100%; }
		.dialog-actions > button { flex: 1 1 auto; }
	}
</style>
