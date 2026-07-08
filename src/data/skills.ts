// 技能数据配置
// 页面保留，暂时不展示任何技能。

export interface Skill {
	name: string;
	description: string;
	icon: string;
	category: "frontend" | "backend" | "database" | "tools" | "other";
	level: number;
	color: string;
	projects?: string[];
}

export const skillsData: Skill[] = [];
