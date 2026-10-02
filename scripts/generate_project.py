from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(name, text):
    key = ident(name)
    objects[key] = text
    return key
def refs(items): return '(' + ','.join(items) + ',)'
def config(name, settings):
    return add(name, '{isa = XCBuildConfiguration; buildSettings = {' + settings + '}; name = ' + name.split(':')[-1] + ';}')
def configs(name, settings):
    debug = config(name + ':Debug', settings + 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf;')
    release = config(name + ':Release', settings + 'SWIFT_OPTIMIZATION_LEVEL = "-O";')
    return add(name + ':configs', '{isa = XCConfigurationList; buildConfigurations = ' + refs([debug, release]) + '; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;}')

target_ids = {name: ident(name + ':target') for name in ['CompassDay', 'CompassDayTests', 'CompassDayUITests']}
groups, products = [], []
for name in target_ids:
    files, builds, resource_builds = [], [], []
    for file in sorted((root / name).glob('*.swift')):
        file_id = add(str(file.relative_to(root)), '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "' + file.name + '"; sourceTree = "<group>";}')
        files.append(file_id)
        builds.append(add(name + ':' + file.name + ':build', '{isa = PBXBuildFile; fileRef = ' + file_id + ';}'))
    for asset in sorted((root / name).glob('*.xcassets')):
        asset_id = add(str(asset.relative_to(root)), '{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = "' + asset.name + '"; sourceTree = "<group>";}')
        files.append(asset_id)
        resource_builds.append(add(name + ':' + asset.name + ':build', '{isa = PBXBuildFile; fileRef = ' + asset_id + ';}'))
    groups.append(add(name + ':group', '{isa = PBXGroup; children = ' + refs(files) + '; path = ' + name + '; sourceTree = "<group>";}'))
    is_app = name == 'CompassDay'
    product = add(name + ':product', '{isa = PBXFileReference; explicitFileType = ' + ('wrapper.application' if is_app else 'wrapper.cfbundle') + '; path = ' + name + ('.app' if is_app else '.xctest') + '; sourceTree = BUILT_PRODUCTS_DIR;}')
    products.append(product)
    sources = add(name + ':sources', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(builds) + '; runOnlyForDeploymentPostprocessing = 0;}')
    frameworks = add(name + ':frameworks', '{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;}')
    phases = [sources, frameworks]
    if resource_builds:
        phases.append(add(name + ':resources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(resource_builds) + '; runOnlyForDeploymentPostprocessing = 0;}'))
    settings = 'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "com.duffy.' + name + '"; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; TARGETED_DEVICE_FAMILY = 1; GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_STYLE = Automatic;'
    dependencies = []
    if is_app:
        settings += 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; INFOPLIST_KEY_CFBundleDisplayName = "Compass Day"; INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = "Your location points the compass to your next saved place and reveals its name when you arrive."; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;'
    else:
        proxy = add(name + ':proxy', '{isa = PBXContainerItemProxy; containerPortal = ' + ident('project') + '; proxyType = 1; remoteGlobalIDString = ' + target_ids['CompassDay'] + '; remoteInfo = CompassDay;}')
        dependencies.append(add(name + ':dependency', '{isa = PBXTargetDependency; target = ' + target_ids['CompassDay'] + '; targetProxy = ' + proxy + ';}'))
        if name == 'CompassDayTests': settings += 'TEST_HOST = "$(BUILT_PRODUCTS_DIR)/CompassDay.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/CompassDay"; BUNDLE_LOADER = "$(TEST_HOST)";'
        else: settings += 'TEST_TARGET_NAME = CompassDay;'
    cl = configs(name, settings)
    add(name + ':target', '{isa = PBXNativeTarget; buildConfigurationList = ' + cl + '; buildPhases = ' + refs(phases) + '; buildRules = (); dependencies = ' + (refs(dependencies) if dependencies else '()') + '; name = ' + name + '; productName = ' + name + '; productReference = ' + product + '; productType = "com.apple.product-type.' + ('application' if is_app else 'bundle.unit-test' if name == 'CompassDayTests' else 'bundle.ui-testing') + '";}')

pg = add('products', '{isa = PBXGroup; children = ' + refs(products) + '; name = Products; sourceTree = "<group>";}')
main = add('main', '{isa = PBXGroup; children = ' + refs(groups + [pg]) + '; sourceTree = "<group>";}')
project_configs = configs('Project', 'SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0;')
add('project', '{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600;}; buildConfigurationList = ' + project_configs + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = ' + main + '; productRefGroup = ' + pg + '; projectDirPath = ""; projectRoot = ""; targets = ' + refs(list(target_ids.values())) + ';}')
(root / 'CompassDay.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(k + ' = ' + v + ';' for k, v in objects.items()) + '\n}; rootObject = ' + ident('project') + ';}\n')
def buildref(name):
    ext = '.app' if name == 'CompassDay' else '.xctest'
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{name}{ext}" BlueprintName="{name}" ReferencedContainer="container:CompassDay.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildref('CompassDay')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildref('CompassDayTests')}</TestableReference><TestableReference skipped="NO">{buildref('CompassDayUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('CompassDay')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildref('CompassDay')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
(root / 'CompassDay.xcodeproj/xcshareddata/xcschemes/CompassDay.xcscheme').write_text(scheme)
