from distutils.core import setup
import glob
import io

def read(*filenames, **kwargs):
    encoding = kwargs.get('encoding', 'utf-8')
    sep = kwargs.get('sep', '\n')
    buf = []
    for filename in filenames:
        with io.open(filename, encoding=encoding) as f:
            buf.append(f.read())
    return sep.join(buf)
    
setup(
    name='emspy',
    version='0.1',
    author='Michael Roth',
    author_email='ems@klimaat.ca',
    packages=['emspy'],
    package_dir = {'': 'lib'},
    scripts=glob.glob('scripts/*.py'),
    url='http://klimaat.ca',
    license='MIT',
    description='A collection of Python scripts to aide in mesoscale modelling using WRF EMS.',
    long_description=read('README.md')
)

