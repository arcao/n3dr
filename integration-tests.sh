#!/bin/bash -e

if [ -z "${APT_GPG_SECRET}" ]; then
  echo "APT_GPG_SECRET should not be empty"
  echo "Create one by running:"
  echo "docker run -v /tmp/gpg-output:/root/.gnupg -v $PWD/tests/gpg/:/tmp/ --rm -it vladgh/gpg --batch --generate-key /tmp/generate"
  echo "docker run --rm -it -v /tmp/gpg-output:/root/.gnupg -v $PWD/tests/gpg/:/tmp/ vladgh/gpg --output /tmp/my_rsa_key --armor --export-secret-key joe@foo.bar"
  echo "Enter 'abc' as a password, if the prompt appears"
  echo "export APT_GPG_SECRET=\$(sudo cat tests/gpg/my_rsa_key | docker run -i m2s:2020-08-05)"
  echo "sudo rm -r /tmp/gpg-output"
  echo "rm tests/gpg/my_rsa_key"
  echo
  echo "Note: Spaces and enters have to be escaped, i.e. '\n'->'\\n' and ' '->'\ ' if the token is used in travis."
  exit 1
fi

NEXUS_VERSION="${1:-3.21.1}"
NEXUS_API_VERSION="${2:-v1}"
TOOL="${3:-./n3dr}"

readonly DOWNLOAD_LOCATION=/tmp/n3dr*

validate(){
  if [ -z "${TOOL}" ]; then
    echo "No deliverable defined. Assuming that 'go run main.go' 
ould be run."
    TOOL="go run main.go"
  fi
  if [ -z "${NEXUS_VERSION}" ] || [ -z "${NEXUS_API_VERSION}" ]; then
    echo "NEXUS_VERSION and NEXUS_API_VERSION should be specified."
    exit 1
  fi
}

build(){
  source ./build.sh
}

nexus(){
  curl -L https://gist.githubusercontent.com/030/666c99d8fc86e9f1cc0ad216e0190574/raw/df8c3140bbfe5a737990b0f4e96594851171f491/nexus-docker.sh -o start.sh
  chmod +x start.sh
  source ./start.sh $NEXUS_VERSION $NEXUS_API_VERSION
}

artifact(){
  mkdir -p "maven-releases/some/group${1}/file${1}/1.0.0"
  echo someContent > "maven-releases/some/group${1}/file${1}/1.0.0/file${1}-1.0.0.jar"
  echo someContentZIP > "maven-releases/some/group${1}/file${1}/1.0.0/file${1}-1.0.0.zip"
  echo -e "<project>\n<modelVersion>4.0.0</modelVersion>\n<groupId>some.group${1}</groupId>\n<artifactId>file${1}</artifactId>\n<version>1.0.0</version>\n</project>" > "maven-releases/some/group${1}/file${1}/1.0.0/file${1}-1.0.0.pom"
}

files(){
  for a in $(seq 100); do artifact "${a}"; done
}

upload(){
  echo "Testing upload..."
  $TOOL upload -u admin -p $PASSWORD -r maven-releases -n http://localhost:9999 -v "${NEXUS_API_VERSION}"
  echo
}

uploadDeb(){
  if [ "${NEXUS_API_VERSION}" != "beta" ]; then
    echo "Creating apt repo..."
    curl -u admin:$PASSWORD \
         -X POST "http://localhost:9999/service/rest/beta/repositories/apt/hosted" \
         -H "accept: application/json" \
         -H "Content-Type: application/json" \
         --data "{\"name\":\"REPO_NAME_HOSTED_APT\",\"online\":true,\"proxy\":{\"remoteUrl\":\"http://nl.archive.ubuntu.com/ubuntu/\"},\"storage\":{\"blobStoreName\":\"default\",\"strictContentTypeValidation\":true,\"writePolicy\":\"ALLOW_ONCE\"},\"apt\": {\"distribution\": \"bionic\"},\"aptSigning\": {\"keypair\": \"${APT_GPG_SECRET}\",\"passphrase\": \"abc\"}}"
  
    mkdir REPO_NAME_HOSTED_APT
    cd REPO_NAME_HOSTED_APT
    curl -L https://github.com/030/a2deb/releases/download/1.0.0/a2deb_1.0.0-0.deb -o a2deb.deb
    curl -L https://github.com/030/n3dr/releases/download/5.0.1/n3dr_5.0.1-0.deb -o n3dr.deb
    curl -L https://github.com/030/informado/releases/download/1.4.0/informado_1.4.0-0.deb -o informado.deb
    cd ..
  
    echo "Testing deb upload..."
    $TOOL upload -u=admin -p="${PASSWORD}" -r=REPO_NAME_HOSTED_APT \
  	           -n=http://localhost:9999 -v="${NEXUS_API_VERSION}" \
  	           -m=false
    echo
  else
    echo "Deb upload not supported in beta API"
  fi
}

backupHelper(){
  if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
    count_downloads 300
    test_zip 148
  else
    count_downloads 400
    test_zip 192
  fi
  cleanup_downloads
}

anonymous(){
  echo "Testing backup by anonymous user..."
  $TOOL backup -n http://localhost:9999 -r maven-releases -v "${NEXUS_API_VERSION}" -z --anonymous
  backupHelper
}

backup(){
  echo "Testing backup..."
  $TOOL backup -n http://localhost:9999 -u admin -p $PASSWORD -r maven-releases -v "${NEXUS_API_VERSION}" -z
  backupHelper
}

regex(){
  echo "Testing backup regex..."
  $TOOL backup -n http://localhost:9999 -u admin -p $PASSWORD -r maven-releases -v "${NEXUS_API_VERSION}" -x 'some/group42' -z
  if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
    count_downloads 3
    test_zip 4
  else
    count_downloads 4
    test_zip 4
  fi
  cleanup_downloads
  echo -e "\nTesting repositories regex..."
  $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v "${NEXUS_API_VERSION}" -b -x 'some/group42' -z
  if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
    count_downloads 3
    test_zip 4
  else
    count_downloads 4
    test_zip 4
  fi
  cleanup_downloads
}

repositories(){
  local cmd="$TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION}"

  echo "Testing repositories..."
  $cmd -a | grep maven-releases
  $cmd -c | grep 5
  $cmd -b -z
  if [ "${NEXUS_VERSION}" == "3.9.0" ]; then
    count_downloads 300
    test_zip 148
  else
    count_downloads 400
    test_zip 192
  fi
  cleanup_downloads
}

zipName(){
  echo "Testing zipName..."
  $TOOL backup -n=http://localhost:9999 -u=admin -p=$PASSWORD -r=maven-releases -v="${NEXUS_API_VERSION}" -z -i=helloZipFile.zip
  $TOOL repositories -n http://localhost:9999 -u admin -p $PASSWORD -v ${NEXUS_API_VERSION} -b -z -i=helloZipRepositoriesFile.zip
  ls helloZip* | wc -l | grep 2
}

clean(){
  cleanup
  cleanup_downloads
}

count_downloads(){
  local actual
  actual=$(find $DOWNLOAD_LOCATION -type f | wc -l)
  echo "Expected: ${1}"
  echo "Actual: ${actual}"
  echo "${actual}" | grep "${1}"
}

test_zip(){
  local size
  size=$(du n3dr-backup-*zip)
  echo "Actual: ${size}"
  echo "Expected: ${1}"
  echo "${size}" | grep "^${1}"
}

cleanup_downloads(){
  rm -rf REPO_NAME_HOSTED_APT
  rm -rf maven-releases
  rm -rf $DOWNLOAD_LOCATION
  rm -f n3dr-backup-*zip
  rm -f helloZip*zip
}

main(){
  validate
  build
  nexus
  readiness
  password
  files
  upload
  anonymous
  backup
  repositories
  regex
  zipName
  uploadDeb
  bats --tap tests.bats
}

trap clean EXIT
main
