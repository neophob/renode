#!/bin/bash

set -e
set -u

THIS_DIR="$(dirname $(realpath ${BASH_SOURCE[0]}))"
cd $THIS_DIR

. common_make_packages.sh

RENODE_ROOT_DIR=$THIS_DIR/../..
RENODE_OUTPUT_DIR=$RENODE_ROOT_DIR/output/bin/$TARGET
RENODE_BIN=$RENODE_OUTPUT_DIR/Renode.exe
DESTINATION=renode_${VERSION}_portable
WORKDIR=$THIS_DIR/renode_${VERSION}_portable-workdir
MONO_VERSION=4.5

mkdir -p $DESTINATION
rm -rf $DESTINATION/*

mkdir $DESTINATION/tests
cp $RENODE_ROOT_DIR/test.sh $DESTINATION
cp -r $RENODE_ROOT_DIR/tests/{robot_tests_provider,run_tests,tests_engine,robot_output_formatter}.py $DESTINATION/tests
cp -r $RENODE_ROOT_DIR/src/Renode/RobotFrameworkEngine/*.{py,robot} $DESTINATION/tests
cp $RENODE_ROOT_DIR/lib/resources/styles/robot.css $DESTINATION/tests/robot.css
cp -r $RENODE_ROOT_DIR/tools/{common.sh,requirements.txt} $DESTINATION/tests

sed -i '/nunit/d' $DESTINATION/tests/run_tests.py
sed -i 's#tools/##' $DESTINATION/test.sh
sed -i 's#ROOT_PATH/tests/run_tests.py#TEST_PATH/run_tests.py#' $DESTINATION/test.sh
sed -i 's#ROOT_PATH}/common.sh#TEST_PATH}/common.sh#' $DESTINATION/test.sh
sed -i 's#--properties-file.*#--robot-framework-remote-server-full-directory=$ROOT_PATH --robot-framework-remote-server-name=renode --css-file=$TEST_PATH/robot.css --runner=none -r . "$@"#' $DESTINATION/test.sh
sed -i '/^ROOT_PATH=.*/a TEST_PATH=$ROOT_PATH/tests' $DESTINATION/test.sh
sed -i '/TESTS_FILE/d' $DESTINATION/test.sh
sed -i '/TESTS_RESULTS/d' $DESTINATION/test.sh
sed -i 's#os\.path\.join(this_path, "\.\./src/Renode/RobotFrameworkEngine/renode-keywords\.robot")#os.path.join(this_path,"renode-keywords.robot")#g' $DESTINATION/tests/robot_tests_provider.py
sed -i 's#^${DIRECTORY}.*#${DIRECTORY}              ${CURDIR}/../bin#' $DESTINATION/tests/renode-keywords.robot

cp -r $RENODE_ROOT_DIR/tests/platforms $DESTINATION/tests/platforms

mkdir -p $WORKDIR
rm -rf $WORKDIR/*

# Prepare dlls config

CONFIG_FILE=$WORKDIR/config
cat /etc/mono/config > $CONFIG_FILE
sed -e 's/$mono_libdir\///g' -i $CONFIG_FILE

# this tag will be added later
sed -e '/<\/configuration>/d' -i $CONFIG_FILE

# this seems to be necessary, otherwise Renode crashes on opening tlib.so in docker
echo '<dllmap dll="i:dl">' >> $CONFIG_FILE
echo '  <dllentry dll="__Internal" name="dlopen" target="dlopen"/>' >> $CONFIG_FILE
echo '</dllmap>' >> $CONFIG_FILE

echo '
  <dllmap dll="libglib-2.0-0.dll" target="libglib-2.0.so.0"/>
  <dllmap dll="libgobject-2.0-0.dll" target="libgobject-2.0.so.0"/>
  <dllmap dll="libgthread-2.0-0.dll" target="libgthread-2.0.so.0"/>

  <dllmap dll="libpango-1.0-0.dll" target="libpango-1.0.so.0"/>
  <dllmap dll="libpangocairo-1.0-0.dll" target="libpangocairo-1.0.so.0"/>

  <dllmap dll="libatk-1.0-0.dll" target="libatk-1.0.so.0"/>

  <dllmap dll="libgtk-win32-2.0-0.dll" target="libgtk-x11-2.0.so.0"/>
  <dllmap dll="libgdk-win32-2.0-0.dll" target="libgdk-x11-2.0.so.0"/>

  <dllmap dll="libgdk_pixbuf-2.0-0.dll" target="libgdk_pixbuf-2.0.so.0"/>

  <dllmap dll="glibsharpglue-2" target="libglibsharpglue-2.so"/>
  <dllmap dll="gtksharpglue-2" target="libgtksharpglue-2.so"/>
  <dllmap dll="gdksharpglue-2" target="libgdksharpglue-2.so"/>
  <dllmap dll="pangosharpglue-2" target="libpangosharpglue-2.so"/>
</configuration>
' >> $CONFIG_FILE

# Generate bundle

ln -sf $RENODE_OUTPUT_DIR/LZ4.dll $WORKDIR/LZ4cc.dll
ln -sf $RENODE_OUTPUT_DIR/LZ4.dll $WORKDIR/LZ4mm.dll
ln -sf $RENODE_OUTPUT_DIR/LZ4.dll $WORKDIR/LZ4pn.dll

# those dlls are copied to a common directory and not
# taken directly from /usr/lib/cli to skip their
# dll.config files - those have absolute paths
# inside which makes portable package not work
# correctly
mkdir -p $WORKDIR/dependencies
cp /usr/lib/cli/atk-sharp-2.0/atk-sharp.dll $WORKDIR/dependencies
cp /usr/lib/cli/gtk-sharp-2.0/gtk-sharp.dll $WORKDIR/dependencies
cp /usr/lib/cli/gdk-sharp-2.0/gdk-sharp.dll $WORKDIR/dependencies
cp /usr/lib/cli/glib-sharp-2.0/glib-sharp.dll $WORKDIR/dependencies
cp /usr/lib/cli/pango-sharp-2.0/pango-sharp.dll $WORKDIR/dependencies

# this is ok to crash here, we will re-compile it
set +e
(cd $WORKDIR; ls $RENODE_OUTPUT_DIR/*.dll | xargs mkbundle \
    --simple \
    --custom \
    --machine-config /etc/mono/$MONO_VERSION/machine.config \
    --config $CONFIG_FILE \
    -L $RENODE_OUTPUT_DIR \
    -L $WORKDIR/dependencies \
    -L /usr/lib/mono/$MONO_VERSION \
    -z --static --keeptemp --nomain \
    $RENODE_BIN 2>/dev/null)
set -e

# Re-compile bundle

WRAPPER_SOURCE_FILE=$WORKDIR/bundler.c

echo "extern int mono_environment_exitcode_get();" > $WRAPPER_SOURCE_FILE
echo "extern void mono_aot_register_module();" >> $WRAPPER_SOURCE_FILE

# this file is generated by `mkbundle`
cat $WORKDIR/temp.c >> $WRAPPER_SOURCE_FILE

# this file is proveded by us
cat $THIS_DIR/linux_portable/additional.c >> $WRAPPER_SOURCE_FILE

gcc \
    -Wl,--wrap=powf  \
    -Wl,--wrap=logf  \
    -Wl,--wrap=expf  \
    -Wl,--wrap=getrandom  \
    -fvisibility=hidden \
    -Wl,--export-dynamic \
    $WRAPPER_SOURCE_FILE  \
    $WORKDIR/temp.s  \
    -I/usr/include/mono-2.0  \
    -lm  \
    -ldl  \
    -lz `pkg-config --libs-only-L mono-2`  \
    -Wl,-Bstatic  \
    -lmono-2.0  \
    -Wl,-Bdynamic `pkg-config --libs-only-l mono-2 | sed -e "s/\-lmono-2.0 //"`  \
    -static-libgcc \
    -o $DESTINATION/renode_bundled

# Copy dependencies

cp $RENODE_OUTPUT_DIR/libllvm-disas.so $DESTINATION

cp $RENODE_ROOT_DIR/.renode-root $DESTINATION
cp -r $RENODE_ROOT_DIR/scripts $DESTINATION
cp -r $RENODE_ROOT_DIR/platforms $DESTINATION

cp /usr/lib/libMonoPosixHelper.so $DESTINATION
cp /usr/lib/libmono-btls-shared.so $DESTINATION

cp /usr/lib/cli/glib-sharp-2.0/libglibsharpglue-2.so $DESTINATION
cp /usr/lib/cli/gtk-sharp-2.0/libgtksharpglue-2.so $DESTINATION
cp /usr/lib/cli/gdk-sharp-2.0/libgdksharpglue-2.so $DESTINATION

cp $THIS_DIR/linux_portable/renode $DESTINATION

# Create tar
mkdir -p ../../output/packages
tar -czf ../../output/packages/renode-$VERSION.linux-portable.tar.gz $DESTINATION

echo "Created a portable package in output/packages/renode-$VERSION.linux-portable.tar.gz"

# Cleanup

if $REMOVE_WORKDIR
then
    rm -rf $DESTINATION
    rm -rf $WORKDIR
fi
