# Function to log start of a operation.
step_log() {
  message=$1
  printf "\n\033[90;1m==> \033[0m\033[37;1m%s\033[0m\n" "$message"
}

# Function to log result of a operation.
add_log() {
  mark=$1
  subject=$2
  message=$3
  if [ "$mark" = "$tick" ]; then
    printf "\033[32;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
  else
    printf "\033[31;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
    [ "$fail_fast" = "true" ] && exit 1;
  fi
}

# Function to log result of installing extension.
add_extension_log() {
  extension=$1
  status=$2
  extension_name=$(echo "$extension" | cut -d '-' -f 1)
  (
    check_extension "$extension_name" && add_log "$tick" "$extension_name" "$status"
  ) || add_log "$cross" "$extension_name" "Could not install $extension on PHP $semver"
}

# Function to read env inputs.
read_env() {
  [[ -z "${update}" ]] && update='false' && UPDATE='false' || update="${update}"
  [ "$update" = false ] && [[ -n ${UPDATE} ]] && update="${UPDATE}"
  [[ -z "${runner}" ]] && runner='github' && RUNNER='github' || runner="${runner}"
  [ "$runner" = false ] && [[ -n ${RUNNER} ]] && runner="${RUNNER}"
}

# Function to setup environment for self-hosted runners.
self_hosted_setup() {
  if [[ $(command -v brew) == "" ]]; then
    step_log "Setup Brew"
    curl "${curl_opts[@]}" https://raw.githubusercontent.com/Homebrew/install/master/install.sh | bash -s 
    add_log "$tick" "Brew" "Installed Homebrew"
  fi
}

# Function to remove extensions.
remove_extension() {
  extension=$1
  if check_extension "$extension"; then
    sudo sed -i '' "/$extension/d" "$ini_file"
    sudo rm -rf "$scan_dir"/*"$extension"* 
    sudo rm -rf "$ext_dir"/"$extension".so 
    (! check_extension "$extension" && add_log "$tick" ":$extension" "Removed") ||
      add_log "$cross" ":$extension" "Could not remove $extension on PHP $semver"
  else
    add_log "$tick" ":$extension" "Could not find $extension on PHP $semver"
  fi
}

# Function to test if extension is loaded.
check_extension() {
  extension=$1
  if [ "$extension" != "mysql" ]; then
    php -m | grep -i -q -w "$extension"
  else
    php -m | grep -i -q "$extension"
  fi
}

# Function to get the PECL version.
get_pecl_version() {
  extension=$1
  stability="$(echo "$2" | grep -m 1 -Eio "(alpha|beta|rc|snapshot)")"
  pecl_rest='https://pecl.php.net/rest/r/'
  response=$(curl "${curl_opts[@]}" "$pecl_rest$extension"/allreleases.xml)
  pecl_version=$(echo "$response" | grep -m 1 -Eio "(\d*\.\d*\.\d*$stability\d*)")
  if [ ! "$pecl_version" ]; then
    pecl_version=$(echo "$response" | grep -m 1 -Eo "(\d*\.\d*\.\d*)")
  fi
  echo "$pecl_version"
}

# Function to install PECL extensions and accept default options
pecl_install() {
  local extension=$1
  yes '' | sudo pecl install -f "$extension" 
}

# Function to install a specific version of PECL extension.
add_pecl_extension() {
  extension=$1
  pecl_version=$2
  prefix=$3
  if [[ $pecl_version =~ .*(alpha|beta|rc|snapshot).* ]]; then
    pecl_version=$(get_pecl_version "$extension" "$pecl_version")
  fi
  if ! check_extension "$extension" && [ -e "$ext_dir/$extension.so" ]; then
    echo "$prefix=$ext_dir/$extension.so" >>"$ini_file"
  fi
  ext_version=$(php -r "echo phpversion('$extension');")
  if [ "$ext_version" = "$pecl_version" ]; then
    add_log "$tick" "$extension" "Enabled"
  else
    remove_extension "$extension" 
    pecl_install "$extension-$pecl_version"
    add_extension_log "$extension-$pecl_version" "Installed and enabled"
  fi
}

# Function to install a php extension from shivammathur/extensions tap.
add_brew_extension() {
  extension=$1
  if ! brew tap | grep shivammathur/extensions; then
    brew tap --shallow shivammathur/extensions
  fi
  brew install "$extension@$version"
  sudo cp "$(brew --prefix)/opt/$extension@$version/$extension.so" "$ext_dir"
}

# Function to setup extensions
add_extension() {
  extension=$1
  install_command=$2
  prefix=$3
  if ! check_extension "$extension" && [ -e "$ext_dir/$extension.so" ]; then
    echo "$prefix=$ext_dir/$extension.so" >>"$ini_file" && add_log "$tick" "$extension" "Enabled"
  elif check_extension "$extension"; then
    add_log "$tick" "$extension" "Enabled"
  elif ! check_extension "$extension"; then
    eval "$install_command"  &&
      if [[ "$version" =~ $old_versions ]]; then echo "$prefix=$ext_dir/$extension.so" >>"$ini_file"; fi
    add_extension_log "$extension" "Installed and enabled"
  fi
}

# Function to setup pre-release extensions using PECL.
add_unstable_extension() {
  extension=$1
  stability=$2
  prefix=$3
  pecl_version=$(get_pecl_version "$extension" "$stability")
  add_pecl_extension "$extension" "$pecl_version" "$prefix"
}

# Function to configure composer
configure_composer() {
  tool_path=$1
  sudo ln -sf "$tool_path" "$tool_path.phar"
  php -r "try {\$p=new Phar('$tool_path.phar', 0);exit(0);} catch(Exception \$e) {exit(1);}"
  if [ $? -eq 1 ]; then
    add_log "$cross" "composer" "Could not download composer"
    exit 1
  fi
  composer -q global config process-timeout 0
  echo "/Users/$USER/.composer/vendor/bin" >> "$GITHUB_PATH"
  if [ -n "$COMPOSER_TOKEN" ]; then
    composer -q global config github-oauth.github.com "$COMPOSER_TOKEN"
  fi
}

# Function to extract tool version.
get_tool_version() {
  tool=$1
  param=$2
  version_regex="[0-9]+((\.{1}[0-9]+)+)(\.{0})(-[a-zA-Z0-9]+){0,1}"
  if [ "$tool" = "composer" ]; then
    if [ "$param" != "snapshot" ]; then
      grep -Ea "const\sVERSION" "$tool_path_dir/composer" | grep -Eo "$version_regex"
    else
      trunk=$(grep -Ea "const\sBRANCH_ALIAS_VERSION" "$tool_path_dir/composer" | grep -Eo "$version_regex")
      commit=$(grep -Ea "const\sVERSION" "$tool_path_dir/composer" | grep -Eo "[a-zA-z0-9]+" | tail -n 1)
      echo "$trunk+$commit"
    fi
  else
    $tool "$param" 2>/dev/null | sed -Ee "s/[Cc]omposer(.)?$version_regex//g" | grep -Eo "$version_regex" | head -n 1
  fi
}

# Function to setup a remote tool.
add_tool() {
  url=$1
  tool=$2
  ver_param=$3
  tool_path="$tool_path_dir/$tool"
  if [ ! -e "$tool_path" ]; then
    rm -rf "$tool_path"
  fi
  if [ "$tool" = "composer" ]; then
    IFS="," read -r -a urls <<< "$url"
    status_code=$(sudo curl -f -w "%{http_code}" -o "$tool_path" "${curl_opts[@]}" "${urls[0]}") ||
    status_code=$(sudo curl -w "%{http_code}" -o "$tool_path" "${curl_opts[@]}" "${urls[1]}")
  else
    status_code=$(sudo curl -w "%{http_code}" -o "$tool_path" "${curl_opts[@]}" "$url")
  fi
  if [ "$status_code" = "200" ]; then
    sudo chmod a+x "$tool_path"
    if [ "$tool" = "composer" ]; then
      configure_composer "$tool_path"
    elif [ "$tool" = "phan" ]; then
      add_extension fileinfo "pecl_install fileinfo" extension 
      add_extension ast "pecl_install ast" extension 
    elif [ "$tool" = "phive" ]; then
      add_extension curl "pecl_install curl" extension 
      add_extension mbstring "pecl_install mbstring" extension 
      add_extension xml "pecl_install xml" extension 
    elif [ "$tool" = "cs2pr" ]; then
      sudo sed -i '' 's/exit(9)/exit(0)/' "$tool_path"
      tr -d '\r' <"$tool_path" | sudo tee "$tool_path.tmp"  && sudo mv "$tool_path.tmp" "$tool_path"
      sudo chmod a+x "$tool_path"
    elif [ "$tool" = "wp-cli" ]; then
      sudo cp -p "$tool_path" "$tool_path_dir"/wp
    fi
    tool_version=$(get_tool_version "$tool" "$ver_param")
    add_log "$tick" "$tool" "Added $tool $tool_version"
  else
    add_log "$cross" "$tool" "Could not setup $tool"
  fi
}

# Function to add a tool using composer.
add_composertool() {
  tool=$1
  release=$2
  prefix=$3
  (
    composer global require "$prefix$release"  &&
    json=$(grep "$prefix$tool" /Users/"$USER"/.composer/composer.json) &&
    tool_version=$(get_tool_version 'echo' "$json") &&
    add_log "$tick" "$tool" "Added $tool $tool_version"
  ) || add_log "$cross" "$tool" "Could not setup $tool"
}

# Function to handle request to add phpize and php-config.
add_devtools() {
  tool=$1
  add_log "$tick" "$tool" "Added $tool $semver"
}

# Function to configure PECL
configure_pecl() {
  for tool in pear pecl; do
    sudo "$tool" config-set php_ini "$ini_file"
    sudo "$tool" channel-update "$tool".php.net
  done
}

# Function to handle request to add PECL.
add_pecl() {
  pecl_version=$(get_tool_version "pecl" "version")
  add_log "$tick" "PECL" "Found PECL $pecl_version"
}

# Function to setup PHP 5.6 and newer.
setup_php() {
  action=$1
  export HOMEBREW_NO_INSTALL_CLEANUP=TRUE
  brew tap --shallow shivammathur/homebrew-php
  if brew list php@"$version" 2>/dev/null | grep -q "Error" && [ "$action" != "upgrade" ]; then
    brew unlink php@"$version"
  else
    brew "$action" shivammathur/php/php@"$version"
  fi
  brew link --force --overwrite php@"$version"
}

# Variables
tick="✓"
cross="✗"
version=$1
dist=$2
fail_fast=$3
nodot_version=${1/./}
old_versions="5.[3-5]"
tool_path_dir="/usr/local/bin"
curl_opts=(-sL)
existing_version=$(php-config --version 2>/dev/null | cut -c 1-3)

read_env
if [ "$runner" = "self-hosted" ]; then
  if [[ "$version" =~ $old_versions ]]; then
    add_log "$cross" "PHP" "PHP $version is not supported on self-hosted runner"
    exit 1
  else
    self_hosted_setup 
  fi
fi

# Setup PHP
step_log "Setup PHP"
if [[ "$version" =~ $old_versions ]]; then
  curl "${curl_opts[@]}" https://github.com/shivammathur/php5-darwin/releases/latest/download/install.sh | bash -s "$nodot_version" 
  status="Installed"
elif [ "$existing_version" != "$version" ]; then
  setup_php "install" 
  status="Installed"
elif [ "$existing_version" = "$version" ] && [ "$update" = "true" ]; then
  setup_php "upgrade" 
  status="Updated to"
else
  status="Found"
fi
ini_file=$(php -d "date.timezone=UTC" --ini | grep "Loaded Configuration" | sed -e "s|.*:s*||" | sed "s/ //g")
sudo chmod 777 "$ini_file" "$tool_path_dir"
echo -e "date.timezone=UTC\nmemory_limit=-1" >>"$ini_file"
ext_dir=$(php -i | grep -Ei "extension_dir => /" | sed -e "s|.*=> s*||")
scan_dir=$(php --ini | grep additional | sed -e "s|.*: s*||")
sudo mkdir -p "$ext_dir"
semver=$(php -v | head -n 1 | cut -f 2 -d ' ')
if [[ ! "$version" =~ $old_versions ]]; then configure_pecl ; fi
sudo cp "$dist"/../src/configs/*.json "$RUNNER_TOOL_CACHE/"
add_log "$tick" "PHP" "$status PHP $semver"
