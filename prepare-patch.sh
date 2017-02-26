#!/usr/bin/env bash
#
# Prepare patches for submission to the Git mailing list.
#
# Usage: prepare-patch.sh [BASE-COMMIT-ISH] [PATCH-VERSION]
#
# ---
#
# Make sure that `git send-email` is configured properly in your Git config.
#
# Here is an example config for Gmail:
#
#   [sendemail]
#      smtpencryption = tls
#      smtpserver = smtp.gmail.com
#      smtpuser = your-user@gmail.com
#      smtpserverport = 587
#      from = Firstname Lastname <your-user@gmail.com>
#
# In addition you need to enable "less securs apps" in Gmail:
#   https://gist.github.com/jasonkarns/4354421
#   https://support.google.com/accounts/answer/6010255?hl=en
#
set -e

EMAIL=TODO@gmail.com
UPSTREAM_REMOTE=upstream
DEFAULT_UPSTREAM_BRANCH=maint
PATCH_TEMP_DIR=~/temp/patches

function msg () {
    echo -e "$(tput setaf 2)$1$(tput sgr 0)\n"
}

function warning () {
    echo -e "\n$(tput setaf 3)###\n### WARNING\n###\n> $(tput sgr 0)$1\n" >&2
}

git fetch $UPSTREAM_REMOTE
BASE_BRANCH=$UPSTREAM_REMOTE/$DEFAULT_UPSTREAM_BRANCH
PATCH_VERSION=1

if [ $# -ge 1 ]; then
    BASE_BRANCH=$1
fi

if [ $# -eq 2 ]; then
    PATCH_VERSION=$2
fi

BASE_HASH=$(git rev-parse $BASE_BRANCH)
HEAD_HASH=$(git rev-parse HEAD)
TOPIC_NAME=$(git rev-parse --abbrev-ref HEAD)

if [ $PATCH_VERSION -ge 2 ]; then
    LAST_PATCH_VERSION=$(($PATCH_VERSION - 1))
    LAST_TAG_NAME="$TOPIC_NAME-v$LAST_PATCH_VERSION"
    LAST_TAG_HASH=$(git ls-remote --tags origin | grep refs/tags/$LAST_TAG_NAME | cut -f 1)
fi

# Generate tag
TAG_NAME="$TOPIC_NAME-v$PATCH_VERSION"
git tag --force $TAG_NAME


########################################################################
msg "Checking commits..."

set +e
git --no-pager diff --check $BASE_HASH...$HEAD_HASH
set -e

# Check committer and author email
AUTHORS=$(git --no-pager log --format="%ae" $BASE_HASH...$HEAD_HASH | uniq)
[ "$AUTHORS" != "$EMAIL" ] && warning "Authors: $AUTHORS"

COMMITTERS=$(git --no-pager log --format="%ce" $BASE_HASH...$HEAD_HASH | uniq)
[ "$COMMITTERS" != "$EMAIL" ] && warning "Committers: $COMMITTERS"

# Check the test cases for spaces after ">"
set +e
git --no-pager diff $BASE_HASH..$HEAD_HASH t | grep "\+.*> .*"
GREP_RETURN_CODE=$?
set -e
if  [ $GREP_RETURN_CODE -eq 0 ]; then
    warning "Spaces after '>' detected!"
fi

# Check for non-ASCII characters in commit messages
NON_ASCII=$(git --no-pager log --pretty=format:"%B" $BASE_HASH...$HEAD_HASH | tr -d "\000-\177")
if [ "$NON_ASCII" != "" ]; then
    git --no-pager log --pretty=format:"%B" $BASE_HASH...$HEAD_HASH
    warning "Non ASCII characters in commit message detected!"
    warning "---$NON_ASCII---"
fi


########################################################################
msg "Compiling patches..."
# git rebase $BASE_HASH -x 'make --quiet -j8;'


########################################################################
msg "Generating patches..."

FORMAT_PATCH_FLAGS="--quiet --notes --find-renames --reroll-count=$PATCH_VERSION --base=$BASE_HASH"
COMMIT_COUNT=$(git --no-pager rev-list $BASE_HASH...$HEAD_HASH --count)

if [ $COMMIT_COUNT -eq "1" ]
then
    BASE_REF=$(git tag --points-at $BASE_HASH)
    # if [ -z $BASE_REF ]
    # then
    #     BASE_REF=${BASE_BRANCH#$UPSTREAM_REMOTE/}
    # fi

    git notes add -f -F- <<EOF
Base Ref: $BASE_REF
Web-Diff: https://github.com/larsxschneider/git/commit/${HEAD_HASH:0:10}
Checkout: git fetch https://github.com/larsxschneider/git $TAG_NAME && git checkout ${HEAD_HASH:0:10}

EOF
    if [ $PATCH_VERSION -ge 2 ]; then
        git notes append -F- <<EOF
Interdiff (v$LAST_PATCH_VERSION..v$PATCH_VERSION):

$(git diff -w $LAST_TAG_HASH $HEAD_HASH)

EOF
    fi
else
    FORMAT_PATCH_FLAGS="$FORMAT_PATCH_FLAGS --cover-letter"
fi

PATCH_DIR=$PATCH_TEMP_DIR/$TOPIC_NAME
rm -rf $PATCH_DIR
mkdir -p $PATCH_DIR

git format-patch $FORMAT_PATCH_FLAGS $BASE_HASH --output-directory $PATCH_DIR/

if [ $COMMIT_COUNT -ne "1" ]
then
    COVER_LETTER="$PATCH_DIR/0000-cover-letter.patch"
    sed -i -e '/^Subject:/{:1;N;/[^\n]$/b1;N;N;N;N;s/^\([^]]*\] \)\*\*\* [^\n]*\(.*\)\n\n\*\*\*[^\n]*\n\n\(.*\)\n$/\1\3\2\n/;:2;n;b2}' "$COVER_LETTER"
    sed -i 's|^//|##|g' "$COVER_LETTER"
    sed -i 's|^///|###|g' "$COVER_LETTER"
    sed -i "s|LAST_PATCH_VERSION|$LAST_PATCH_VERSION|g" "$COVER_LETTER"
    if [ -n "$LAST_PATCH_VERSION" ]
    then
        split -p ^-- "$COVER_LETTER" "$COVER_LETTER-split-"
        cat "$COVER_LETTER-split-aa" > "$COVER_LETTER"
        printf "\n\n## Interdiff ($LAST_PATCH_VERSION..$PATCH_VERSION)\n\n" >> "$COVER_LETTER"
        git diff -w $TOPIC_NAME/$LAST_PATCH_VERSION $HEAD_HASH >> "$COVER_LETTER"
        printf "\n" >> "$COVER_LETTER"
        cat "$COVER_LETTER-split-ab" >> "$COVER_LETTER"
        rm "$COVER_LETTER-split-aa" "$COVER_LETTER-split-ab"
    fi
fi


########################################################################
msg "Looking for potential reviewers..."
# Based on Alek Storm's script:
# https://gist.github.com/alekstorm/4949628

function createBlameParts {
    awk -v commit="$BASE_HASH" '{
        if ($1 == "@@") {
            sub(",", ",+", $2)
            # -MC: Detect moved/copied lines across files
            # -w : Ignore whitespace changes
            # -L : Range
            print "git blame --line-porcelain -MCw -L " substr($2,2) " " commit
        }
        else
            print "-- " substr($3,3)
    }'
}

function concatBlameParts {
    awk '{
        if (match($0, /^--/) == 1)
            file=$0
        else
            print $0 " " file
    }'
}

function execBlame {
    while read COMMAND; do
        $COMMAND | sed -n "s/^author-mail <\([^>]*\)>$/\1/p"
    done
}

ELEVATE_RECENT_CONTRIBUTORS=$(
    git log --all --since="52 weeks ago" --pretty=format:%ae |
        sort |
        uniq |
        awk '{printf "-e /%s/s/^[[:space:]]*/9999999/ ",$0}'
)

REVIEWERS=$(
    git diff --diff-filter=DM "$BASE_HASH..$HEAD_HASH" |
        egrep '^@|^diff' |
        createBlameParts |
        concatBlameParts |
        execBlame |
        sort |
        uniq -c |
        grep -v $EMAIL |
        sed $ELEVATE_RECENT_CONTRIBUTORS |
        sort -nr |
        head -n 5 |
        awk '{printf "--cc="$2" ",$0}'
)


########################################################################
$(git config core.editor) $PATCH_DIR &

echo ""
echo "Send patch with:"
echo "git push origin $TAG_NAME && git send-email $PATCH_DIR/* --to=git@vger.kernel.org $REVIEWERS --in-reply-to="
