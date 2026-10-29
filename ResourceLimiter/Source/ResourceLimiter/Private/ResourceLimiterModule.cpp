// Level Editor toolbar toggle for ResourceLimiterCore, plus the engine-side part of each level:
// the texture streaming pool (video memory) and a frame cap (GPU load).

#include "HAL/IConsoleManager.h"
#include "Interfaces/IPluginManager.h"
#include "Modules/ModuleManager.h"
#include "ResourceLimiterCore.h"
#include "RHI.h"
#include "Styling/AppStyle.h"
#include "Styling/SlateStyle.h"
#include "Styling/SlateStyleRegistry.h"
#include "ToolMenus.h"
#include "Widgets/Images/SImage.h"
#include "Widgets/Input/SButton.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Text/STextBlock.h"

#define LOCTEXT_NAMESPACE "ResourceLimiter"

DEFINE_LOG_CATEGORY_STATIC(LogResourceLimiterUI, Log, All);

using ResourceLimiter::ELevel;

class FResourceLimiterModule : public IModuleInterface
{
public:
	virtual void StartupModule() override
	{
		Style = MakeShared<FSlateStyleSet>("ResourceLimiterStyle");
		Style->SetContentRoot(IPluginManager::Get().FindPlugin(TEXT("ResourceLimiter"))->GetBaseDir() / TEXT("Resources"));
		Style->Set("ResourceLimiter.Cpu", new FSlateVectorImageBrush(Style->RootToContentDir(TEXT("Cpu"), TEXT(".svg")), FVector2D(16.f, 16.f)));
		FSlateStyleRegistry::RegisterSlateStyle(*Style);

		// ResourceLimiterCore already applied the CPU part of the saved level at startup.
		Level = ResourceLimiter::LoadLevel();
		ApplyEngineLimits();

		UToolMenus::RegisterStartupCallback(FSimpleMulticastDelegate::FDelegate::CreateRaw(this, &FResourceLimiterModule::RegisterMenus));

		LevelCommand = IConsoleManager::Get().RegisterConsoleCommand(
			TEXT("ResourceLimiter.Level"),
			TEXT("Sets the Resource Limiter level for this session without saving it: 90, 70, 50 or off."),
			FConsoleCommandWithArgsDelegate::CreateLambda([this](const TArray<FString>& Args)
			{
				const FString Arg = Args.Num() > 0 ? Args[0] : FString();
				for (int32 Index = 0; Index < ResourceLimiter::NumLevels; ++Index)
				{
					const int32 Cpu = ResourceLimiter::GetLevelSettings((ELevel)Index).CpuPercent;
					if ((Cpu == 0 && Arg.Equals(TEXT("off"), ESearchCase::IgnoreCase)) || (Cpu > 0 && Arg == FString::FromInt(Cpu)))
					{
						SetLevel((ELevel)Index, false);
						return;
					}
				}
				UE_LOG(LogResourceLimiterUI, Warning, TEXT("ResourceLimiter.Level: expected 90, 70, 50 or off."));
			}));
	}

	virtual void ShutdownModule() override
	{
		if (LevelCommand)
		{
			IConsoleManager::Get().UnregisterConsoleObject(LevelCommand);
			LevelCommand = nullptr;
		}
		if (UObjectInitialized())
		{
			UToolMenus::UnRegisterStartupCallback(this);
			UToolMenus::UnregisterOwner(this);
		}
		if (Style.IsValid())
		{
			FSlateStyleRegistry::UnRegisterSlateStyle(*Style);
			Style.Reset();
		}
	}

private:
	void RegisterMenus()
	{
		FToolMenuOwnerScoped OwnerScoped(this);

		UToolMenu* ToolBar = UToolMenus::Get()->ExtendMenu("LevelEditor.LevelEditorToolBar.User");
		FToolMenuSection& Section = ToolBar->FindOrAddSection("ResourceLimiter");

		TSharedRef<SWidget> Button =
			SNew(SButton)
			.ButtonStyle(FAppStyle::Get(), "SimpleButton")
			.ContentPadding(FMargin(2.f))
			.ToolTipText_Raw(this, &FResourceLimiterModule::GetTooltip)
			.OnClicked_Lambda([this]() { Cycle(); return FReply::Handled(); })
			[
				SNew(SBorder)
				.BorderImage(FAppStyle::Get().GetBrush("WhiteBrush"))
				.BorderBackgroundColor_Raw(this, &FResourceLimiterModule::GetBackgroundColor)
				.Padding(FMargin(4.f, 2.f))
				[
					SNew(SHorizontalBox)
					+ SHorizontalBox::Slot()
					.AutoWidth()
					.VAlign(VAlign_Center)
					[
						SNew(SImage)
						.Image(Style->GetBrush("ResourceLimiter.Cpu"))
						.ColorAndOpacity_Raw(this, &FResourceLimiterModule::GetForegroundColor)
					]
					+ SHorizontalBox::Slot()
					.AutoWidth()
					.VAlign(VAlign_Center)
					.Padding(FMargin(3.f, 0.f, 0.f, 0.f))
					[
						SNew(STextBlock)
						.Text_Raw(this, &FResourceLimiterModule::GetLabel)
						.ColorAndOpacity_Raw(this, &FResourceLimiterModule::GetForegroundColor)
					]
				]
			];

		Section.AddEntry(FToolMenuEntry::InitWidget("ResourceLimiterButton", Button, LOCTEXT("ButtonLabel", "Resource Limiter"), true));
	}

	void Cycle()
	{
		SetLevel((ELevel)(((int32)Level + 1) % ResourceLimiter::NumLevels), true);
	}

	void SetLevel(ELevel NewLevel, bool bSave)
	{
		Level = NewLevel;
		ResourceLimiter::ApplyProcessLimits(Level);
		ApplyEngineLimits();
		if (bSave)
		{
			ResourceLimiter::SaveLevel(Level);
		}
	}

	void ApplyEngineLimits()
	{
		const ResourceLimiter::FLevelSettings& Settings = ResourceLimiter::GetLevelSettings(Level);
		ApplyTexturePool(Settings.TexturePoolPercent);
		ApplyFrameCap(Settings.MaxFps);
	}

	// Shrinks the texture streaming pool (the editor's main video-memory user) to a share of the size the engine chose.
	void ApplyTexturePool(int32 Percent)
	{
		IConsoleVariable* PoolSize = IConsoleManager::Get().FindConsoleVariable(TEXT("r.Streaming.PoolSize"));
		if (!PoolSize)
		{
			return;
		}
		if (Percent <= 0)
		{
			if (bChangedPool)
			{
				PoolSize->Set(OriginalPoolSetting, ECVF_SetByCode);
				bChangedPool = false;
			}
			return;
		}

		// Remember the engine's own pool the first time we change it (it is only sized after the first streaming update).
		if (!bChangedPool)
		{
			OriginalPoolSetting = PoolSize->GetInt();
			OriginalPoolMB = GTexturePoolSize > 0 ? int32(GTexturePoolSize / (1024 * 1024)) : OriginalPoolSetting;
		}

		if (OriginalPoolMB <= 0)
		{
			return;
		}
		const int32 TargetMB = FMath::Max(64, OriginalPoolMB * Percent / 100);
		PoolSize->Set(TargetMB, ECVF_SetByCode);
		bChangedPool = true;
		UE_LOG(LogResourceLimiterUI, Log, TEXT("Texture streaming pool capped at %d MB (%d%% of the engine's %d MB)."), TargetMB, Percent, OriginalPoolMB);
	}

	// Sets t.MaxFPS only when nothing else (a console command, FPS Lock, a project setting) has set it.
	void ApplyFrameCap(float MaxFps)
	{
		IConsoleVariable* MaxFpsVar = IConsoleManager::Get().FindConsoleVariable(TEXT("t.MaxFPS"));
		if (!MaxFpsVar)
		{
			return;
		}
		const bool bOurs = AppliedFps > 0.f && MaxFpsVar->GetFloat() == AppliedFps;
		const bool bFree = MaxFpsVar->GetFloat() == 0.f && (MaxFpsVar->GetFlags() & ECVF_SetByMask) <= ECVF_SetByCode;
		if (MaxFps > 0.f && (bOurs || bFree))
		{
			MaxFpsVar->Set(MaxFps, ECVF_SetByCode);
			AppliedFps = MaxFps;
		}
		else if (MaxFps <= 0.f && bOurs)
		{
			MaxFpsVar->Set(0.f, ECVF_SetByCode);
			AppliedFps = 0.f;
		}
	}

	FSlateColor GetBackgroundColor() const
	{
		switch (Level)
		{
		case ELevel::Cap50: return FLinearColor(0.85f, 0.12f, 0.1f);
		case ELevel::Cap70: return FLinearColor(1.f, 0.5f, 0.f);
		case ELevel::Cap90: return FLinearColor(0.15f, 0.75f, 0.2f);
		default:            return FLinearColor::Transparent;
		}
	}

	FSlateColor GetForegroundColor() const
	{
		return Level == ELevel::Off ? FSlateColor::UseForeground() : FSlateColor(FLinearColor::Black);
	}

	FText GetLabel() const
	{
		const int32 Cpu = ResourceLimiter::GetLevelSettings(Level).CpuPercent;
		return Cpu > 0 ? FText::AsNumber(Cpu) : LOCTEXT("LabelOff", "Off");
	}

	FText GetTooltip() const
	{
		const ResourceLimiter::FLevelSettings& Settings = ResourceLimiter::GetLevelSettings(Level);
		const ResourceLimiter::FLevelSettings& Next = ResourceLimiter::GetLevelSettings((ELevel)(((int32)Level + 1) % ResourceLimiter::NumLevels));
		const FText NextText = Next.CpuPercent > 0
			? FText::Format(LOCTEXT("NextCap", "Click: cap at {0}%."), Next.CpuPercent)
			: LOCTEXT("NextOff", "Click: remove the limits.");
		if (Settings.CpuPercent <= 0)
		{
			return FText::Format(LOCTEXT("TipOff", "Resource Limiter: off. The editor may use the whole machine.\n{0}"), NextText);
		}
		return FText::Format(LOCTEXT("TipOn",
			"Resource Limiter: {0}%\n"
			"- CPU: editor and shader compilers together capped at {0}% of all cores{1}\n"
			"- Memory: {2}\n"
			"- Video memory: texture streaming pool cut to {3}% of its normal size\n"
			"- GPU: frame rate capped at {4} fps unless another cap is set\n"
			"{5}"),
			Settings.CpuPercent,
			Settings.bBelowNormalPriority ? LOCTEXT("LowPriority", ", below-normal priority") : FText::GetEmpty(),
			Settings.MemoryPriority < 5 ? LOCTEXT("MemLow", "lower priority, so Windows gives other programs RAM first") : LOCTEXT("MemNormal", "normal"),
			Settings.TexturePoolPercent,
			FText::AsNumber((int32)Settings.MaxFps),
			NextText);
	}

	TSharedPtr<FSlateStyleSet> Style;
	IConsoleObject* LevelCommand = nullptr;
	ELevel Level = ELevel::Off;

	bool bChangedPool = false;
	int32 OriginalPoolSetting = 0;
	int32 OriginalPoolMB = 0;
	float AppliedFps = 0.f;
};

#undef LOCTEXT_NAMESPACE

IMPLEMENT_MODULE(FResourceLimiterModule, ResourceLimiter)
