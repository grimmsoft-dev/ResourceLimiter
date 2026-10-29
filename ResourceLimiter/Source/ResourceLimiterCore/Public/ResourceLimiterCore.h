#pragma once

#include "CoreMinimal.h"

namespace ResourceLimiter
{
	// Toolbar levels in click order. The number is the CPU cap.
	enum class ELevel : int32 { Off = 0, Cap90 = 1, Cap70 = 2, Cap50 = 3 };
	static constexpr int32 NumLevels = 4;

	struct FLevelSettings
	{
		int32 CpuPercent;          // hard cap for the editor and every process it starts (shader compilers...); 0 = none
		bool bBelowNormalPriority; // let other programs win when they compete for the CPU
		uint32 MemoryPriority;     // Windows page priority, 1 (very low) to 5 (normal): lower is trimmed first under memory pressure
		int32 TexturePoolPercent;  // texture streaming pool (video memory), % of the size the engine picked; 0 = unchanged
		float MaxFps;              // frame cap applied when no other cap is set; 0 = none
	};

	RESOURCELIMITERCORE_API const FLevelSettings& GetLevelSettings(ELevel Level);

	// The chosen level, saved per user for all projects (EditorSettings.ini, [ResourceLimiter]).
	RESOURCELIMITERCORE_API ELevel LoadLevel();
	RESOURCELIMITERCORE_API void SaveLevel(ELevel Level);

	// Applies the CPU cap, process priority and memory priority of a level.
	RESOURCELIMITERCORE_API bool ApplyProcessLimits(ELevel Level);
}
