import importTest from './Import.test';
import engineTest from './Engine.test';
import utdTest from './Utd.test';
import openWithTest from './OpenWith.test';

export default function testsuite() {
  importTest();
  engineTest();
  utdTest();
  openWithTest();
}
