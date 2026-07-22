import I18nKey from "@/i18n/i18nKey";
import { i18n } from "@/i18n/translation";

export interface PostHomeContentData {
	description?: string;
	hideHomeContent?: boolean;
	password?: string | null;
	restricted?: boolean;
}

function hasPassword(password?: string | null): boolean {
	return typeof password === "string" && password.length > 0;
}

export function shouldHidePostHomeContent(data: PostHomeContentData): boolean {
	return (
		data.restricted || (data.hideHomeContent ?? hasPassword(data.password))
	);
}

export function getPostHomeContent(
	data: PostHomeContentData,
	excerpt: string,
): string {
	return getPostPublicDescription(data, excerpt);
}

export function getPostPublicDescription(
	data: PostHomeContentData,
	fallback = "",
): string {
	if (data.restricted) {
		return i18n(I18nKey.postRestrictedMessage);
	}

	if (shouldHidePostHomeContent(data)) {
		return i18n(I18nKey.postEncryptedMessage);
	}

	return data.description || fallback;
}
