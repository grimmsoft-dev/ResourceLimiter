using UnrealBuildTool;

public class ResourceLimiterCore : ModuleRules
{
	public ResourceLimiterCore(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		// Loads right after config (before the shader compile workers start), so it can only use Core.
		PublicDependencyModuleNames.Add("Core");
	}
}
