import type { ProfileConfig } from "../types/config";

// 个人资料配置
export const profileConfig: ProfileConfig = {
	avatar: "assets/images/avatar.webp", // 相对于 /src 目录。如果以 '/' 开头，则相对于 /public 目录
	name: "許洛長安",
	bio: "我是許洛長安",
	typewriter: {
		enable: true, // 启用个人简介打字机效果
		speed: 80, // 打字速度（毫秒）
	},
	links: [
		{
			name: "Bilibili",
			icon: "fa7-brands:bilibili",
			url: "https://space.bilibili.com/505033391",
		},
		{
			name: "GitHub",
			icon: "fa7-brands:github",
			url: "https://github.com/xuluochangan/xuluochangan-blog",
		},
	],
};
