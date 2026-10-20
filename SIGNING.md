# 发布签名迁移方案（暂不执行）

- 状态：**方案已就绪，未切换**。当前线上包继续用 Android Debug 证书发布。
- 决策依据：换成正式 keystore 后，已安装用户会因签名不匹配**无法覆盖升级**，
  必须卸载重装，而掌握度、复习排程、自由造句次数全部存在本机 Hive 里，
  卸载即归零。在用户量起来之前，这个代价不划算。

## 一、现状取证（2026-10-20 实测）

```
$ apksigner verify --print-certs build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 certificate SHA-256 digest: 3244b4f8af39a4fca1b6dbef5fdac8bacf7e0b8cf88cae33094b2428ece77465
```

`android/app/build.gradle` 里仍是 Flutter 模板原样：

```groovy
signingConfig = signingConfigs.getByName("debug")   // TODO: Add your own signing config
```

## 二、这条路的实际后果

| 后果 | 说明 |
|---|---|
| 不能上架任何商店 | Google Play / 各安卓商店都要求正式签名 |
| 「谁发布的」无法证明 | `CN=Android Debug` 是全世界每个 Android 开发者共用的证书名，不构成来源凭证 |
| 日后必须付一次断代成本 | 换证书的**那一刻**起，旧包与新包签名不同，只能卸载重装 |
| keystore 丢失即永久断代 | 正式证书一旦丢了，老用户永远收不到更新，且无法再发同包名的包 |

第二行最需要注意：招聘或对外介绍时，「release 包用 debug 证书」是一个会被一眼看到的硬伤。

## 三、切换步骤（决定要切的时候照做）

1. **生成并离线备份 keystore**（密码只存在你脑子里 + 密码管理器，绝不进 git）：

   ```bash
   keytool -genkeypair -v -keystore chunkspoke-release.jks -alias chunkspoke \
     -keyalg RSA -keysize 2048 -validity 10000
   ```

2. 把 `chunkspoke-release.jks` 与 `android/key.properties` 加入 `.gitignore`，
   `key.properties` 内容：`storePassword` / `keyPassword` / `storeFile` / `keyAlias`。

3. `android/app/build.gradle` 改成读 `key.properties`：存在则用 release 证书，
   缺失则回落到 debug 并**打印醒目告警**（防止 CI 无声发出 debug 签名的「release」包）。

4. 在 Release 说明与官网公告里写明：**本版起需卸载重装，学习进度会丢失**；
   同时把 `version.json` 的 `notes` 也带上这句话——它是更新弹窗唯一能露字的地方。

5. 备份三件套（缺一不可）：keystore 文件、storePassword、keyPassword。
   建议至少两处异地，且包含你手机里那份 APK 的 `apksigner` 输出，以便日后比对。

## 四、公告草稿（切换那一版直接用）

> **重要：本次更新需要卸载重装**
>
> 从 v1.x.x 起，ChunkSpoke 改用正式发布证书（此前为调试证书，无法上架应用商店）。
> 签名变更后系统不允许覆盖安装，请先卸载旧版本再安装新版。
>
> 代价：所有学习进度（已掌握词块、复习排程、自由造句次数）只保存在本机，
> 卸载后会清零，目前没有云端同步。如果你不想丢进度，可以先不更新，
> 等做完进度导出再升级。对带来的不便我负全部责任。

## 五、如果想「切但不断代」

只有一条路：**先做进度导出/导入**（把 Hive 数据序列化成可分享文件或导出到用户自己的网盘），
再切签名。工作量约 1 天，能同时解掉「换机即丢进度」这个更长期的高优问题。
建议把它排在签名迁移之前。
