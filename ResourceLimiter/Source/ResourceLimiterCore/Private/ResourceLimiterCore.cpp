// Puts the editor in a Windows job object as soon as config is loaded. Processes the editor starts afterwards
// (shader compile workers, the engine's own kill-on-exit job) end up inside it, so one CPU-rate cap on the job
// limits all of them together.

#include "ResourceLimiterCore.h"

#include "Misc/ConfigCacheIni.h"
#include "Modules/ModuleManager.h"

#include "Windows/AllowWindowsPlatformTypes.h"
#include <Windows.h>
#include "Windows/HideWindowsPlatformTypes.h"

DEFINE_LOG_CATEGORY_STATIC(LogResourceLimiter, Log, All);

namespace ResourceLimiter
{
	static const TCHAR* ConfigSection = TEXT("ResourceLimiter");
	static const TCHAR* ConfigKey = TEXT("Level");

	static const FLevelSettings Levels[NumLevels] =
	{
		//  CPU   below normal  memory  texture pool  fps
		{   0,    false,        5,      0,            0.f   }, // Off
		{   90,   false,        5,      90,           120.f }, // 90
		{   70,   true,         4,      70,           60.f  }, // 70
		{   50,   true,         2,      50,           30.f  }, // 50
	};

	// Unreal compiles against the Windows 7 API; these Windows 8+ declarations are spelled out here.
	static constexpr int32 JobObjectCpuRateControlInformationClass = 15;
	static constexpr DWORD CpuRateControlEnable = 0x1;
	static constexpr DWORD CpuRateControlHardCap = 0x4;
	struct FCpuRateControlInformation { DWORD ControlFlags; DWORD CpuRate; };

	static constexpr int32 ProcessMemoryPriorityClass = 0;
	struct FMemoryPriorityInformation { ULONG MemoryPriority; };
	typedef BOOL (WINAPI* FSetProcessInformation)(HANDLE, int32, LPVOID, DWORD);

	static HANDLE Job = nullptr;

	const FLevelSettings& GetLevelSettings(ELevel Level)
	{
		return Levels[FMath::Clamp((int32)Level, 0, NumLevels - 1)];
	}

	ELevel LoadLevel()
	{
		int32 Saved = (int32)ELevel::Off;
		if (GConfig && !GEditorSettingsIni.IsEmpty())
		{
			GConfig->GetInt(ConfigSection, ConfigKey, Saved, GEditorSettingsIni);
		}
		return (ELevel)FMath::Clamp(Saved, 0, NumLevels - 1);
	}

	void SaveLevel(ELevel Level)
	{
		GConfig->SetInt(ConfigSection, ConfigKey, (int32)Level, GEditorSettingsIni);
		GConfig->Flush(false, GEditorSettingsIni);
	}

	bool ApplyProcessLimits(ELevel Level)
	{
		const FLevelSettings& Settings = GetLevelSettings(Level);
		bool bOk = true;

		if (Job)
		{
			FCpuRateControlInformation Rate = {};
			if (Settings.CpuPercent > 0)
			{
				Rate.ControlFlags = CpuRateControlEnable | CpuRateControlHardCap;
				Rate.CpuRate = (DWORD)Settings.CpuPercent * 100; // in 1/100ths of a percent of all cores
			}
			if (!SetInformationJobObject(Job, (JOBOBJECTINFOCLASS)JobObjectCpuRateControlInformationClass, &Rate, sizeof(Rate)))
			{
				UE_LOG(LogResourceLimiter, Warning, TEXT("Could not set the CPU cap (error %u)."), GetLastError());
				bOk = false;
			}
		}
		else if (Settings.CpuPercent > 0)
		{
			bOk = false;
		}

		SetPriorityClass(GetCurrentProcess(), Settings.bBelowNormalPriority ? BELOW_NORMAL_PRIORITY_CLASS : NORMAL_PRIORITY_CLASS);

		if (const FSetProcessInformation SetProcessInformation = (FSetProcessInformation)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "SetProcessInformation"))
		{
			FMemoryPriorityInformation MemoryPriority = { Settings.MemoryPriority };
			SetProcessInformation(GetCurrentProcess(), ProcessMemoryPriorityClass, &MemoryPriority, sizeof(MemoryPriority));
		}

		if (Settings.CpuPercent > 0)
		{
			UE_LOG(LogResourceLimiter, Log, TEXT("Level %d: CPU capped at %d%%%s, memory priority %u."), Settings.CpuPercent,
				Settings.CpuPercent, bOk ? TEXT("") : TEXT(" (FAILED)"), Settings.MemoryPriority);
		}
		else
		{
			UE_LOG(LogResourceLimiter, Log, TEXT("Level off: no CPU cap."));
		}
		return bOk;
	}
}

class FResourceLimiterCoreModule : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		using namespace ResourceLimiter;

		Job = CreateJobObjectW(nullptr, nullptr);
		if (!Job || !AssignProcessToJobObject(Job, GetCurrentProcess()))
		{
			UE_LOG(LogResourceLimiter, Warning, TEXT("Could not put the editor in a job object (error %u); the CPU cap is unavailable."), GetLastError());
			if (Job)
			{
				CloseHandle(Job);
				Job = nullptr;
			}
		}

		const ELevel Level = LoadLevel();
		if (Level != ELevel::Off)
		{
			ApplyProcessLimits(Level);
		}
	}

	virtual void ShutdownModule() override
	{
		// The job (and the cap) stays with the process until it exits; nothing to undo.
	}
};

IMPLEMENT_MODULE(FResourceLimiterCoreModule, ResourceLimiterCore)
