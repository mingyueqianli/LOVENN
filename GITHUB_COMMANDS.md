# GitHub 发布命令

下面把 `YOURNAME` 改成你的 GitHub 用户名。

## 1. 本地初始化仓库并上传

```bash
cd LOVENN_GitHub_Release

git init
git add .
git commit -m "Initial release: Love v8 project panel"

git branch -M main
git remote add origin https://github.com/YOURNAME/LOVENN.git
git push -u origin main
```

## 2. 服务器一键安装命令

### wget

```bash
sudo -i
bash <(wget -qO- https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh)
```

### curl

```bash
sudo -i
curl -fsSL https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh | bash
```

## 3. 后续更新脚本

服务器里运行：

```bash
Love update-channel
Love self-update
```

也可以：

```bash
export LOVE_UPDATE_URL="https://raw.githubusercontent.com/YOURNAME/LOVENN/main/Love.sh"
Love self-update
```

## 4. GitHub Release 打包

服务器上可以运行：

```bash
Love release
```

本地也可以直接压缩仓库：

```bash
zip -r LOVENN-release.zip Love.sh README.md LICENSE CHANGELOG.md install.sh .github SECURITY.md .gitignore
```

## 5. 检查脚本语法

```bash
bash -n Love.sh
bash -n install.sh
```
