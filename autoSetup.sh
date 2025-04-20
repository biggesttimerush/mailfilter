#!/bin/bash

# Read which package manager to use and set distro-specific variables
if [ $# == 0 ]; then
  echo "Please enter a package manager to use. Example: $0 dnf"
  exit 1
fi

os_id=$(grep -E '^ID=' /etc/os-release | grep -E -o '[a-z]+')
latest_apptainer_version=`wget -nv -O - https://github.com/apptainer/apptainer/releases | grep -E -i -o "v[0-9]+\.[0-9]+\.[0-9]+" \
| head -n 1 | grep -E -i -o "[0-9]+\.[0-9]+\.[0-9]+"`

if [ $1 == "dnf" ]; then
  pm_name="dnf"
  mimedefang_config_path="/etc/sysconfig/mimedefang"
  if [ $os_id == "fedora" ]; then
    echo -e "\nallow spamd_t self:user_namespace create;\n" | tee -a ./mimedefang-apptainer.te
  fi
  
  # Update all packages plus extra repos and apptainer
  sudo $pm_name update -q -y
  sudo $pm_name install -q -y epel-release epel-next-release
  sudo /usr/bin/crb enable
  sudo $pm_name update -q -y
  sudo $pm_name install -q -y apptainer

  # Allow MIMEDefang service to run apptainer on distros with SELinux
  # See mimedefang-apptainer.te for plaintext version of policy module
  sudo setsebool -P use_fusefs_home_dirs=on domain_can_mmap_files=on
  checkmodule -M -m -o mimedefang-apptainer.mod mimedefang-apptainer.te
  semodule_package -o mimedefang-apptainer.pp -m mimedefang-apptainer.mod
  sudo semodule -X 300 -i mimedefang-apptainer.pp

elif [ $1 == "apt" ]; then
  pm_name="apt"
  mimedefang_config_path="/etc/default/mimedefang"

  # Update all packages plus install apptainer
  sudo $pm_name update -q && sudo $pm_name upgrade -q -y
  wget -nv https://github.com/apptainer/apptainer/releases/download/v${latest_apptainer_version}/apptainer_${latest_apptainer_version}_amd64.deb
  sudo $pm_name install -q -y ./apptainer_${latest_apptainer_version}_amd64.deb
  rm apptainer_${latest_apptainer_version}_amd64.deb

else
  echo "Package manager "$1" is not recognized. Currently supported package manager(s): apt dnf"
  exit 1
fi

# Set distro-agnostic variables
postfix_config_path="/etc/postfix/main.cf"

# Install necessary packages
sudo $pm_name install -q -y postfix
sudo $pm_name install -q -y mimedefang

# Set up Postfix and MIMEDefang communication socket
echo "# Socket for communicating with MIMEDefang" | sudo tee -a $postfix_config_path
echo "# Note that systemd requires the use of a dynamic/private port (port number between 49152-65535)" \
| sudo tee -a $postfix_config_path
echo "# If this arbitrary port number is changed, you must also change the line 'SOCKET=inet:#####@localhost' \
in /etc/sysconfig/mimedefang to match the chosen port" | sudo tee -a $postfix_config_path
echo "smtpd_milters = inet:localhost:50997" | sudo tee -a $postfix_config_path

echo "# Set maximum total message size that will be accepted to 25 MiB (default 10 MB)" | sudo tee -a $postfix_config_path
echo "message_size_limit = 26214400" | sudo tee -a $postfix_config_path

echo "# Socket for communicating with Postfix" | sudo tee -a $mimedefang_config_path
echo "# Note that systemd requires the use of a dynamic/private port (port number between 49152-65535)" \
| sudo tee -a $mimedefang_config_path
echo "# If this arbitrary port number is changed, you must also change the line 'smtpd_milters = inet:localhost:#####' \
in /etc/postfix/main.cf to match the chosen port" | sudo tee -a $mimedefang_config_path
echo "SOCKET=inet:50997@localhost" | sudo tee -a $mimedefang_config_path

# Add MIMEDefang filter rule to run PDF attachments through the pdfDefang.sif apptainer
sudo sed -i "187 i ##### Added by autoSetup.sh\n\
    # Run external command to sanitize PDF\n\
    if (lc(\$type) eq 'application/pdf') {\n\
        md_syslog('warning', 'DEBUG: filter. PDF file detected');\n\n\
        if (action_external_filter(\$entity, 'apptainer run --userns /usr/local/share/pdfDefang.sif ./FILTERINPUT')) {\n\
            md_syslog('warning', 'DEBUG: filter. Conversion command successful.');\n\
            return action_accept_with_warning('The attached PDF has been sanitized.');\n\
        }\n\
        else {\n\
            return action_drop_with_warning('PDF filter failed, an attachement was removed.');\n\
        }\n\
    }" /etc/mail/mimedefang-filter

# Make pdfDefang executable before building the apptainer image
sudo chmod +x pdfDefang

# Create apptainer image to run the pdfDefang script; image is built according to pdfDefang.def
apptainer build -F --userns pdfDefang.sif pdfDefang.def

# Move apptainer image so user defang can access it
sudo cp pdfDefang.sif /usr/local/share/pdfDefang.sif
rm pdfDefang.sif

# Start MIMEDefang and Postfix and set them to run on start up
sudo systemctl enable mimedefang.service
sudo systemctl enable postfix.service
sudo systemctl start mimedefang.service
sudo systemctl start postfix.service


# ========================= DEBUG/TESTING =========================
# Download smtp command line utility for testing setup; sample command at EOF
wget https://raw.githubusercontent.com/mludvig/smtp-cli/refs/heads/master/smtp-cli
chmod +x smtp-cli
if [ $1 == "dnf" ]; then
  sudo $pm_name install -q -y perl-CPAN
elif [ $1 == "apt" ]; then
  sudo $pm_name install -q -y idn2
  sudo echo "yes" | sudo cpan Term::ReadKey Digest::HMAC_MD5 Net::DNS
fi
sudo echo "yes" | sudo cpan MIME::Lite File::Type File::LibMagic IO::Socket::INET6

# Install Neomutt and Okular for testing
sudo $pm_name install -q -y neomutt
sudo $pm_name install -q -y okular
if [ $1 == "dnf" ]; then
  sudo $pm_name install -q -y setroubleshoot
fi

# Possible testing command using smtp-cli (executable script should be in the directory you ran autoSetup in)
# ./smtp-cli --verbose --server localhost --user <username> --pass <password> --to <username>@<localhostname>.localdomain --subject "Test Subject $(date)" --body-plain "Body text with PDF file attached" --attach <filename>.pdf
