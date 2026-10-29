using UnrealBuildTool;

public class ResourceLimiter : ModuleRules
{
	public ResourceLimiter(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PrivateDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"Projects",
			"RHI",
			"Slate",
			"SlateCore",
			"ToolMenus",
			"ResourceLimiterCore"
		});
	}
}
